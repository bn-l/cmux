#!/usr/bin/env python3
"""Regression: claude hooks route to the agent's real pane, never a recycled tty or a poisoned record.

Three failures used to compound after a restart:

1. The app re-seeds its tty table from the previous run's snapshot, and macOS recycles
   `ttysNNN` names, so right after a relaunch a name is commonly attributed to a
   DIFFERENT project's pane. The hook resolved by tty first and recorded the session
   under that pane.
2. Every later hook for that session preferred the recorded pane over the agent's real
   one, so status pills, notifications and resume bindings all followed the poison.
3. The wrong binding was persisted at quit and replayed on the next launch.

These tests drive the real CLI against a fake socket where the tty table and the process
tree DISAGREE, which is exactly the post-restart state, and assert the process tree wins
and the record is rewritten.
"""

from __future__ import annotations

import json
import os
import shutil
import socket
import subprocess
import tempfile
import threading
import time
import uuid
from pathlib import Path

CLAUDE_PID = 424242


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit:
        if os.path.exists(explicit) and os.access(explicit, os.X_OK):
            return explicit
        raise RuntimeError(f"Configured cmux CLI is not executable: {explicit}")

    in_path = shutil.which("cmux")
    if in_path:
        return in_path

    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


class RoutingSocketServer:
    """Two workspaces, one pane each, plus a deliberately stale tty table.

    `agent_pid_surface` is where `system.top` reports the agent process — the ground
    truth. `tty_surface` is what `debug.terminals` claims for the caller's tty — the
    stale, post-restart attribution.
    """

    def __init__(self, tty_name: str) -> None:
        self.tty_name = tty_name
        self.workspace_a = str(uuid.uuid4()).upper()
        self.surface_a = str(uuid.uuid4()).upper()
        self.workspace_b = str(uuid.uuid4()).upper()
        self.surface_b = str(uuid.uuid4()).upper()
        self.window_id = str(uuid.uuid4()).upper()
        # Defaults: the tty table names workspace B, the process tree names workspace A.
        self.tty_workspace = self.workspace_b
        self.tty_surface = self.surface_b
        self.agent_pid_workspace: str | None = self.workspace_a
        self.agent_pid_surface: str | None = self.surface_a

        self.commands: list[str] = []
        self.ready = threading.Event()
        self.stop = threading.Event()
        self.error: Exception | None = None
        self.root = tempfile.TemporaryDirectory(prefix="cmux-claude-routing-")
        self.socket_path = os.path.join(self.root.name, "cmux.sock")
        self.thread = threading.Thread(target=self._run, daemon=True)
        self.server: socket.socket | None = None

    def __enter__(self) -> "RoutingSocketServer":
        self.thread.start()
        if not self.ready.wait(timeout=2.0):
            raise RuntimeError("socket server did not become ready")
        if self.error is not None:
            raise self.error
        return self

    def __exit__(self, _exc_type: object, _exc: object, _tb: object) -> None:
        self.stop.set()
        if self.server is not None:
            self.server.close()
        self.thread.join(timeout=2.0)
        self.root.cleanup()

    def _run(self) -> None:
        try:
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as server:
                self.server = server
                server.bind(self.socket_path)
                server.listen(8)
                server.settimeout(0.1)
                self.ready.set()
                while not self.stop.is_set():
                    try:
                        conn, _ = server.accept()
                    except socket.timeout:
                        continue
                    except OSError:
                        return
                    threading.Thread(target=self._handle, args=(conn,), daemon=True).start()
        except Exception as exc:  # noqa: BLE001 - surfaced to the test body
            self.error = exc
            self.ready.set()

    def _handle(self, conn: socket.socket) -> None:
        with conn:
            conn.settimeout(0.1)
            buffer = b""
            idle_deadline = time.time() + 6.0
            while not self.stop.is_set() and time.time() < idle_deadline:
                try:
                    chunk = conn.recv(4096)
                except socket.timeout:
                    continue
                if not chunk:
                    break
                idle_deadline = time.time() + 2.0
                buffer += chunk
                while b"\n" in buffer:
                    raw_line, buffer = buffer.split(b"\n", 1)
                    if not raw_line:
                        continue
                    line = raw_line.decode("utf-8", errors="replace")
                    self.commands.append(line)
                    try:
                        conn.sendall((self._response_for(line) + "\n").encode("utf-8"))
                    except (BrokenPipeError, ConnectionResetError):
                        # The CLI closes a connection as soon as it has what it needs
                        # (the `system.top` probe opens its own short-lived one).
                        return

    def _surfaces_for(self, workspace_id: str | None) -> list[dict[str, object]]:
        if workspace_id == self.workspace_a:
            surface_id = self.surface_a
        elif workspace_id == self.workspace_b:
            surface_id = self.surface_b
        else:
            return []
        return [{"index": 0, "id": surface_id, "ref": "surface:1", "focused": True}]

    def _system_top(self) -> dict[str, object]:
        workspaces: list[dict[str, object]] = []
        for workspace_id, surface_id in (
            (self.workspace_a, self.surface_a),
            (self.workspace_b, self.surface_b),
        ):
            hosts_agent = (
                self.agent_pid_workspace == workspace_id
                and self.agent_pid_surface == surface_id
            )
            workspaces.append(
                {
                    "id": workspace_id,
                    "panes": [
                        {
                            "surfaces": [
                                {
                                    "id": surface_id,
                                    "top_level_pids": [CLAUDE_PID] if hosts_agent else [],
                                    "processes": [],
                                }
                            ]
                        }
                    ],
                }
            )
        return {"windows": [{"id": self.window_id, "workspaces": workspaces}]}

    def _response_for(self, line: str) -> str:
        if not line.startswith("{"):
            return "OK"
        try:
            request = json.loads(line)
        except json.JSONDecodeError:
            return "OK"

        method = request.get("method")
        params = request.get("params") or {}
        result: dict[str, object] = {}
        if method == "surface.list":
            result = {"surfaces": self._surfaces_for(params.get("workspace_id"))}
        elif method == "workspace.current":
            result = {"workspace_id": self.workspace_a}
        elif method == "workspace.list":
            result = {
                "workspaces": [
                    {"index": 0, "id": self.workspace_a, "ref": "workspace:1"},
                    {"index": 1, "id": self.workspace_b, "ref": "workspace:2"},
                ]
            }
        elif method == "window.list":
            result = {"windows": [{"id": self.window_id}]}
        elif method == "debug.terminals":
            result = {
                "terminals": [
                    {
                        "tty": f"/dev/{self.tty_name}",
                        "workspace_id": self.tty_workspace,
                        "surface_id": self.tty_surface,
                    }
                ]
            }
        elif method == "system.top":
            result = self._system_top()

        return json.dumps({"id": request.get("id"), "ok": True, "result": result})


def run_claude_hook(
    cli_path: str,
    socket_path: str,
    subcommand: str,
    payload: dict[str, object],
    env: dict[str, str],
) -> None:
    proc = subprocess.run(
        [cli_path, "--socket", socket_path, "claude-hook", subcommand],
        input=json.dumps(payload),
        text=True,
        capture_output=True,
        env=env,
        timeout=20,
        check=False,
    )
    if proc.returncode != 0:
        raise RuntimeError(
            f"cmux claude-hook {subcommand} failed:\n"
            f"exit={proc.returncode}\nstdout={proc.stdout}\nstderr={proc.stderr}"
        )


def hook_env(server: RoutingSocketServer, state_path: Path, **overrides: str) -> dict[str, str]:
    env = os.environ.copy()
    env["CMUX_SOCKET_PATH"] = server.socket_path
    env["CMUX_CLAUDE_HOOK_STATE_PATH"] = str(state_path)
    env["CMUX_CLI_TTY_NAME"] = server.tty_name
    env["CMUX_CLI_SENTRY_DISABLED"] = "1"
    env["CMUX_CLAUDE_HOOK_SENTRY_DISABLED"] = "1"
    env.update(overrides)
    return env


def seed_session_record(
    state_path: Path,
    session_id: str,
    workspace_id: str,
    surface_id: str,
    pid: int | None,
) -> None:
    record: dict[str, object] = {
        "sessionId": session_id,
        "workspaceId": workspace_id,
        "surfaceId": surface_id,
        "cwd": "/tmp",
        "isRestorable": True,
        "startedAt": 1.0,
        "updatedAt": 1.0,
    }
    if pid is not None:
        record["pid"] = pid
    state_path.write_text(
        json.dumps({"version": 1, "sessions": {session_id: record}}, indent=2)
    )


def read_record(state_path: Path, session_id: str) -> dict[str, object]:
    state = json.loads(state_path.read_text())
    return state.get("sessions", {}).get(session_id, {})


def commands_targeting(commands: list[str], workspace_id: str) -> list[str]:
    return [line for line in commands if f"--tab={workspace_id}" in line]


def check_session_start_prefers_process_tree_over_stale_tty(cli_path: str) -> str | None:
    """A recycled tty name must not decide where a new session is recorded."""
    with RoutingSocketServer(tty_name="ttys005") as server:
        state_path = Path(server.root.name) / "claude-hook-state.json"
        session_id = f"start-{uuid.uuid4().hex}"
        env = hook_env(
            server,
            state_path,
            CMUX_WORKSPACE_ID=server.workspace_a,
            CMUX_SURFACE_ID=server.surface_a,
            CMUX_CLAUDE_PID=str(CLAUDE_PID),
        )

        run_claude_hook(
            cli_path,
            server.socket_path,
            "session-start",
            {"session_id": session_id, "source": "clear", "cwd": "/tmp"},
            env,
        )

        record = read_record(state_path, session_id)
        if record.get("workspaceId") != server.workspace_a:
            return (
                "session-start recorded the tty pane instead of the pane hosting the "
                f"agent process: workspaceId={record.get('workspaceId')!r} "
                f"expected={server.workspace_a!r}"
            )
        if record.get("surfaceId") != server.surface_a:
            return (
                "session-start recorded the wrong surface: "
                f"surfaceId={record.get('surfaceId')!r} expected={server.surface_a!r}"
            )
        if commands_targeting(server.commands, server.workspace_b):
            return (
                "session-start mutated the stale-tty workspace: "
                f"{commands_targeting(server.commands, server.workspace_b)!r}"
            )
    return None


def check_prompt_submit_heals_a_poisoned_record(cli_path: str) -> str | None:
    """A record pointing at the wrong pane must be corrected, not obeyed."""
    with RoutingSocketServer(tty_name="ttys006") as server:
        state_path = Path(server.root.name) / "claude-hook-state.json"
        session_id = f"heal-{uuid.uuid4().hex}"
        # The poison: the record names workspace B, but the agent lives in A.
        seed_session_record(
            state_path,
            session_id,
            workspace_id=server.workspace_b,
            surface_id=server.surface_b,
            pid=CLAUDE_PID,
        )
        env = hook_env(
            server,
            state_path,
            CMUX_WORKSPACE_ID=server.workspace_a,
            CMUX_SURFACE_ID=server.surface_a,
            CMUX_CLAUDE_PID=str(CLAUDE_PID),
        )

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            env,
        )

        record = read_record(state_path, session_id)
        if record.get("workspaceId") != server.workspace_a:
            return (
                "prompt-submit followed the poisoned record instead of healing it: "
                f"workspaceId={record.get('workspaceId')!r} expected={server.workspace_a!r}"
            )
        if record.get("surfaceId") != server.surface_a:
            return (
                "prompt-submit left the poisoned surface in place: "
                f"surfaceId={record.get('surfaceId')!r} expected={server.surface_a!r}"
            )
        if not commands_targeting(server.commands, server.workspace_a):
            return f"prompt-submit sent nothing to the live pane: {server.commands!r}"
        if commands_targeting(server.commands, server.workspace_b):
            return (
                "prompt-submit still mutated the poisoned pane: "
                f"{commands_targeting(server.commands, server.workspace_b)!r}"
            )
    return None


def check_recorded_pane_with_dead_pid_is_not_preferred(cli_path: str) -> str | None:
    """With no live process anywhere, the shell's own pane still outranks the record."""
    with RoutingSocketServer(tty_name="ttys007") as server:
        # Nothing hosts the agent pid, and the tty table names nobody real.
        server.agent_pid_workspace = None
        server.agent_pid_surface = None
        server.tty_workspace = server.workspace_b
        server.tty_surface = server.surface_b

        state_path = Path(server.root.name) / "claude-hook-state.json"
        session_id = f"dead-{uuid.uuid4().hex}"
        seed_session_record(
            state_path,
            session_id,
            workspace_id=server.workspace_b,
            surface_id=server.surface_b,
            pid=987654321,
        )
        env = hook_env(
            server,
            state_path,
            CMUX_WORKSPACE_ID=server.workspace_a,
            CMUX_SURFACE_ID=server.surface_a,
        )

        run_claude_hook(
            cli_path,
            server.socket_path,
            "prompt-submit",
            {"session_id": session_id, "turn_id": "turn-1", "cwd": "/tmp"},
            env,
        )

        record = read_record(state_path, session_id)
        if record.get("surfaceId") != server.surface_a:
            return (
                "a record whose pid is gone was still preferred over the caller's own "
                f"pane: surfaceId={record.get('surfaceId')!r} expected={server.surface_a!r}"
            )
    return None


def main() -> int:
    try:
        cli_path = resolve_cmux_cli()
    except Exception as exc:  # noqa: BLE001 - reported as a test failure
        print(f"FAIL: {exc}")
        return 1

    checks = (
        check_session_start_prefers_process_tree_over_stale_tty,
        check_prompt_submit_heals_a_poisoned_record,
        check_recorded_pane_with_dead_pid_is_not_preferred,
    )
    for check in checks:
        failure = check(cli_path)
        if failure is not None:
            print(f"FAIL[{check.__name__}]: {failure}")
            return 1
        print(f"ok: {check.__name__}")

    print("PASS: claude hooks route to the agent's real pane")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
