#!/usr/bin/env python3
"""Regression: cmux's Claude hooks must not write to stdout.

Claude Code adds a hook's plain stdout to the model's context for SessionStart
and UserPromptSubmit. The hook handlers printed "OK", so the model received
"SessionStart:startup hook success: OK" once per session and
"UserPromptSubmit hook success: OK" on every prompt. Nothing reads the
handlers' stdout: the hooks exist to drive cmux's sidebar status and
notifications.

Runs every hook command the Claude wrapper registers the way Claude Code runs
it (`sh -c <command>` with the event payload on stdin) against a fake cmux
socket, and checks that:
- every `hooks claude <sub>` command exits 0 with empty stdout and still sends
  the socket commands that do its job;
- `hooks feed --source claude` still answers with JSON (PermissionRequest
  decisions travel on that stdout);
- usage text still prints;
- the legacy `cmux claude-hook <sub>` entry point is silent too;
- a socket that errors or hangs up does not make a hook print, or exit 2
  (which would block the prompt in Claude Code).
"""

from __future__ import annotations

import glob
import json
import os
import re
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
WRAPPER = REPO / "Resources" / "bin" / "cmux-claude-wrapper"
FAKE_AGENT_PID = "424242"

# Every `hooks claude` subcommand the wrapper registers. A wrapper change that
# adds or drops one must update this list (and EFFECTS below), so the test can
# never pass by running fewer hooks than Claude Code does.
EXPECTED_CLAUDE_SUBCOMMANDS = {
    "session-start",
    "prompt-submit",
    "pre-tool-use",
    "push-notification",
    "notification",
    "stop",
    "auto-name",
    "session-end",
}

# The order Claude Code fires them in one session, so session-end finds the
# session record the earlier hooks created.
EVENT_ORDER = [
    "SessionStart",
    "UserPromptSubmit",
    "PreToolUse",
    "PostToolUse",
    "Notification",
    "PermissionRequest",
    "Stop",
    "SubagentStop",
    "SessionEnd",
]

EVENT_PAYLOADS = {
    "SessionStart": {"source": "startup"},
    "UserPromptSubmit": {"prompt": "next step"},
    "PreToolUse": {"tool_name": "Bash", "tool_input": {"command": "ls"}},
    "PostToolUse": {
        "tool_name": "PushNotification",
        "tool_input": {"message": "done"},
        "tool_response": {"message": "done", "localSent": True},
    },
    "Notification": {"message": "Claude is waiting for your input", "notification_type": "idle_prompt"},
    "PermissionRequest": {"tool_name": "Bash", "tool_input": {"command": "rm -rf build"}},
    "Stop": {"stop_hook_active": False, "last_assistant_message": "Refactored the parser."},
    "SubagentStop": {"stop_hook_active": False, "agent_id": "agent-1", "agent_type": "general-purpose"},
    "SessionEnd": {"reason": "exit"},
}

# A socket command each handler must still send: proof that silencing stdout
# did not silence the hook. `{ws}`, `{surf}` and `{pid}` are filled in.
EFFECTS = {
    "session-start": ["set_agent_pid claude_code {pid} --tab={ws} --panel={surf}"],
    "prompt-submit": [
        "set_agent_lifecycle claude_code running --tab={ws} --panel={surf}",
        "set_status claude_code Running --icon=bolt.fill",
    ],
    "pre-tool-use": ["set_agent_lifecycle claude_code running --tab={ws} --panel={surf}"],
    "push-notification": ["notify_target_async {ws} {surf} Claude Code||done"],
    "notification": [
        "notify_target_async {ws} {surf} Claude Code|Waiting|Claude is waiting for your input|c=idle-reminder;p=0",
    ],
    "stop": [
        "set_agent_lifecycle claude_code idle --tab={ws} --panel={surf}",
        "notify_target_async {ws} {surf} Claude Code|Completed in ",
    ],
    "auto-name": ['"method":"workspace.set_auto_title"'],
    "session-end": ["clear_agent_pid claude_code --tab={ws} --panel={surf}"],
}

CLAUDE_COMMAND = re.compile(r'^"\$\{CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux\}" hooks claude ([a-z-]+)$')
FEED_COMMAND = '"${CMUX_CLAUDE_HOOK_CMUX_BIN:-cmux}" hooks feed --source claude'


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit:
        if os.path.exists(explicit) and os.access(explicit, os.X_OK):
            return explicit
        raise RuntimeError(f"Configured cmux CLI is not executable: {explicit}")

    # No /tmp globbing: /tmp is world-writable, so auto-discovering and
    # executing binaries from it is unsafe. CI always passes CMUX_CLI_BIN.
    candidates = [
        path
        for path in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux"))
        if os.path.exists(path) and os.access(path, os.X_OK)
    ]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


def load_hook_commands() -> list[tuple[str, str]]:
    """The wrapper's hooks as (event, command), in EVENT_ORDER."""
    match = re.search(r"^HOOKS_JSON='(.*?)'\s*$", WRAPPER.read_text(encoding="utf-8"), re.M)
    if match is None:
        raise RuntimeError(f"HOOKS_JSON not found in {WRAPPER}")
    hooks = json.loads(match.group(1))["hooks"]
    unknown_events = sorted(set(hooks) - set(EVENT_ORDER))
    if unknown_events:
        raise RuntimeError(f"wrapper registers events this test has no payload for: {unknown_events}")
    commands = [
        (event, hook["command"])
        for event in EVENT_ORDER
        for group in hooks.get(event, [])
        for hook in group["hooks"]
    ]
    unknown = [command for _, command in commands if not CLAUDE_COMMAND.match(command) and command != FEED_COMMAND]
    if unknown:
        raise RuntimeError(f"wrapper registers hook commands this test does not know: {unknown}")
    found = {claude.group(1) for _, command in commands if (claude := CLAUDE_COMMAND.match(command))}
    if found != EXPECTED_CLAUDE_SUBCOMMANDS:
        raise RuntimeError(
            "wrapper's `hooks claude` subcommands changed: "
            f"missing={sorted(EXPECTED_CLAUDE_SUBCOMMANDS - found)} new={sorted(found - EXPECTED_CLAUDE_SUBCOMMANDS)}"
        )
    return commands


class FakeCmuxSocket:
    """Records every line. mode "ok" answers like cmux; "error" answers every
    request with an error; "hangup" closes each connection without reading."""

    def __init__(self, workspace_id: str, surface_id: str, mode: str = "ok") -> None:
        self.workspace_id = workspace_id
        self.surface_id = surface_id
        self.mode = mode
        self.commands: list[str] = []
        self.lock = threading.Lock()
        self.root = tempfile.TemporaryDirectory(prefix="cmux-hook-stdout-")
        self.socket_path = os.path.join(self.root.name, "cmux.sock")
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.thread = threading.Thread(target=self._accept_loop, daemon=True)

    def __enter__(self) -> "FakeCmuxSocket":
        self.server.bind(self.socket_path)
        self.server.listen(16)
        self.thread.start()
        return self

    def __exit__(self, *_exc: object) -> None:
        self.server.close()
        self.thread.join(timeout=2.0)
        self.root.cleanup()

    def snapshot(self) -> list[str]:
        with self.lock:
            return list(self.commands)

    def _accept_loop(self) -> None:
        while True:
            try:
                conn, _ = self.server.accept()
            except OSError:
                return
            if self.mode == "hangup":
                conn.close()
                continue
            threading.Thread(target=self._serve, args=(conn,), daemon=True).start()

    def _serve(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(5.0)
            buffer = b""
            while True:
                try:
                    chunk = conn.recv(65536)
                except OSError:
                    return
                if not chunk:
                    return
                buffer += chunk
                while b"\n" in buffer:
                    raw, buffer = buffer.split(b"\n", 1)
                    if not raw:
                        continue
                    line = raw.decode("utf-8", errors="replace")
                    with self.lock:
                        self.commands.append(line)
                    reply = self._reply(line)
                    if reply is None:
                        continue
                    try:
                        conn.sendall((reply + "\n").encode("utf-8"))
                    except OSError:
                        return

    def _reply(self, line: str) -> str | None:
        if not line.startswith("{"):
            return "ERROR: injected failure" if self.mode == "error" else "OK"
        request = json.loads(line)
        if "id" not in request:
            return None
        if self.mode == "error":
            return json.dumps({"id": request["id"], "ok": False, "error": {"code": "injected", "message": "injected failure"}})
        result: dict = {}
        if request.get("method") == "surface.list":
            result = {"surfaces": [{"id": self.surface_id, "ref": self.surface_id, "workspace_id": self.workspace_id}]}
        return json.dumps({"id": request["id"], "ok": True, "result": result})


class HookRunner:
    """One Claude session's worth of hook runs: shared ids, state file and
    sandboxed HOME. The environment is built from scratch so the caller's own
    cmux pane (socket, ids, agent shims) can never leak in."""

    def __init__(self, cli: str, server: FakeCmuxSocket) -> None:
        self.cli = cli
        self.server = server
        self.home = tempfile.mkdtemp(prefix="cmux-hook-stdout-home-")
        self.session_id = f"stdout-{uuid.uuid4().hex}"
        self.env = {
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": self.home,
            "TMPDIR": self.home,
            "CMUX_CLAUDE_HOOK_CMUX_BIN": cli,
            "CMUX_SOCKET_PATH": server.socket_path,
            "CMUX_WORKSPACE_ID": server.workspace_id,
            "CMUX_TAB_ID": server.workspace_id,
            "CMUX_SURFACE_ID": server.surface_id,
            "CMUX_PANEL_ID": server.surface_id,
            "CMUX_CLAUDE_PID": FAKE_AGENT_PID,
            "CMUX_CLAUDE_HOOK_STATE_PATH": os.path.join(self.home, "claude-hook-sessions.json"),
        }

    def payload(self, event: str) -> str:
        return json.dumps(
            {
                "hook_event_name": event,
                "session_id": self.session_id,
                "cwd": self.home,
                "transcript_path": os.path.join(self.home, "transcript.jsonl"),
                **EVENT_PAYLOADS[event],
            }
        )

    def run_shell(self, command: str, event: str) -> tuple[subprocess.CompletedProcess, list[str]]:
        before = len(self.server.snapshot())
        proc = subprocess.run(
            ["sh", "-c", command],
            input=self.payload(event),
            text=True,
            capture_output=True,
            env=self.env,
            timeout=30,
            check=False,
        )
        time.sleep(0.05)
        return proc, self.server.snapshot()[before:]

    def run_cli(self, args: list[str], event: str | None = None) -> tuple[subprocess.CompletedProcess, list[str]]:
        before = len(self.server.snapshot())
        proc = subprocess.run(
            [self.cli, *args],
            input=self.payload(event) if event else "",
            text=True,
            capture_output=True,
            env=self.env,
            timeout=30,
            check=False,
        )
        time.sleep(0.05)
        return proc, self.server.snapshot()[before:]

    def expected(self, subcommand: str) -> list[str]:
        return [
            fragment.format(ws=self.server.workspace_id, surf=self.server.surface_id, pid=FAKE_AGENT_PID)
            for fragment in EFFECTS[subcommand]
        ]


def describe(proc: subprocess.CompletedProcess) -> str:
    return f"exit={proc.returncode} stdout={proc.stdout!r} stderr={proc.stderr[-300:]!r}"


def check_every_wrapper_hook(cli: str, commands: list[tuple[str, str]], failures: list[str]) -> None:
    with FakeCmuxSocket(str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()) as server:
        runner = HookRunner(cli, server)
        for event, command in commands:
            proc, sent = runner.run_shell(command, event)
            claude = CLAUDE_COMMAND.match(command)
            hook_args = command.split('}" ', 1)[-1]
            label = f"{event} `{hook_args}`"
            if claude is None:
                # hooks feed: its stdout is the hook's answer to Claude Code.
                if proc.returncode != 0:
                    failures.append(f"{label}: feed hook failed: {describe(proc)}")
                    continue
                try:
                    json.loads(proc.stdout)
                except json.JSONDecodeError:
                    failures.append(f"{label}: feed hook must answer with JSON: {describe(proc)}")
                continue
            if proc.returncode != 0 or proc.stdout != "":
                failures.append(f"{label}: expected exit 0 and empty stdout: {describe(proc)}")
            for fragment in runner.expected(claude.group(1)):
                if not any(fragment in line for line in sent):
                    failures.append(f"{label}: hook no longer sent {fragment!r}; sent={sent!r}")


def check_permission_request_feed_answers(cli: str, failures: list[str]) -> None:
    with FakeCmuxSocket(str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()) as server:
        runner = HookRunner(cli, server)
        proc, _ = runner.run_shell(FEED_COMMAND, "PermissionRequest")
        try:
            answer = json.loads(proc.stdout)
        except json.JSONDecodeError:
            failures.append(f"PermissionRequest feed: stdout is not JSON: {describe(proc)}")
            return
        if proc.returncode != 0 or answer != {}:
            failures.append(f"PermissionRequest feed: expected `{{}}` (no decision from the socket): {describe(proc)}")


def check_legacy_entry_point(cli: str, failures: list[str]) -> None:
    with FakeCmuxSocket(str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()) as server:
        runner = HookRunner(cli, server)
        for subcommand, event in (("session-start", "SessionStart"), ("prompt-submit", "UserPromptSubmit")):
            proc, sent = runner.run_cli(["claude-hook", subcommand], event)
            if proc.returncode != 0 or proc.stdout != "":
                failures.append(f"legacy `claude-hook {subcommand}`: expected exit 0 and empty stdout: {describe(proc)}")
            for fragment in runner.expected(subcommand):
                if not any(fragment in line for line in sent):
                    failures.append(f"legacy `claude-hook {subcommand}`: hook no longer sent {fragment!r}; sent={sent!r}")


def check_usage_still_prints(cli: str, failures: list[str]) -> None:
    with FakeCmuxSocket(str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper()) as server:
        runner = HookRunner(cli, server)
        proc, _ = runner.run_cli(["claude-hook", "help"])
        if proc.returncode != 0 or "cmux claude-hook <session-start" not in proc.stdout:
            failures.append(f"`claude-hook help` must print its usage line: {describe(proc)}")
        for args in (["claude-hook", "--help"], ["claude-hook", "-h"], ["hooks", "claude", "--help"]):
            proc, _ = runner.run_cli(args)
            if proc.returncode != 0 or not proc.stdout.strip():
                failures.append(f"`{' '.join(args)}` must print help: {describe(proc)}")


def check_failing_socket_stays_silent(cli: str, commands: list[tuple[str, str]], failures: list[str]) -> None:
    for mode in ("error", "hangup"):
        with FakeCmuxSocket(str(uuid.uuid4()).upper(), str(uuid.uuid4()).upper(), mode=mode) as server:
            runner = HookRunner(cli, server)
            for event, command in commands:
                claude = CLAUDE_COMMAND.match(command)
                if claude is None or claude.group(1) not in {"session-start", "prompt-submit", "notification", "stop"}:
                    continue
                proc, _ = runner.run_shell(command, event)
                label = f"{event} `{claude.group(1)}` with a socket that {'errors' if mode == 'error' else 'hangs up'}"
                if proc.stdout != "":
                    failures.append(f"{label}: stdout must stay empty: {describe(proc)}")
                if proc.returncode not in (0, 1):
                    # 2 would block the prompt in Claude Code; a signal means a crash.
                    failures.append(f"{label}: expected exit 0 or 1: {describe(proc)}")


def main() -> int:
    try:
        cli = resolve_cmux_cli()
        commands = load_hook_commands()
    except Exception as exc:
        print(f"FAIL: {exc}")
        return 1

    failures: list[str] = []
    check_every_wrapper_hook(cli, commands, failures)
    check_permission_request_feed_answers(cli, failures)
    check_legacy_entry_point(cli, failures)
    check_usage_still_prints(cli, failures)
    check_failing_socket_stays_silent(cli, commands, failures)

    if failures:
        print(f"FAIL: {len(failures)} problem(s) with Claude hook stdout (cli={cli})")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"PASS: all {len(commands)} wrapper hooks keep stdout empty and still do their job")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
