#!/usr/bin/env python3
"""End-to-end checks for `cmux completion <shell>` and `cmux __complete`.

Runs the real CLI binary and the generated scripts in real zsh, bash and fish.
A fake cmux socket serves `workspace.list` so live handle completion is tested
without a running app, and a stalled socket proves completion stays bounded.
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
from pathlib import Path


def resolve_cmux_cli() -> str:
    explicit = os.environ.get("CMUX_CLI_BIN") or os.environ.get("CMUX_CLI")
    if explicit and os.path.isfile(explicit) and os.access(explicit, os.X_OK):
        return explicit
    candidates = [
        path
        for path in glob.glob(os.path.expanduser("~/Library/Developer/Xcode/DerivedData/*/Build/Products/Debug/cmux"))
        if os.path.isfile(path) and os.access(path, os.X_OK)
    ]
    if candidates:
        candidates.sort(key=os.path.getmtime, reverse=True)
        return candidates[0]
    raise RuntimeError("Unable to find cmux CLI binary. Set CMUX_CLI_BIN.")


class FakeCmuxSocket:
    """Answers each v2 request line; `stall` accepts but never replies."""

    def __init__(self, path: Path, stall: bool = False) -> None:
        self.path = path
        self.stall = stall
        self.methods: list[str] = []
        self.server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.server.bind(str(path))
        self.server.listen(8)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def serve(self) -> None:
        while True:
            try:
                connection, _ = self.server.accept()
            except OSError:
                return
            with connection:
                buffer = b""
                while b"\n" not in buffer:
                    chunk = connection.recv(65536)
                    if not chunk:
                        break
                    buffer += chunk
                if not buffer or self.stall:
                    time.sleep(5)
                    continue
                request = json.loads(buffer.split(b"\n", 1)[0])
                self.methods.append(request["method"])
                result = {"workspaces": [{"ref": "workspace:7"}, {"ref": "workspace:8"}]}
                reply = {"id": request["id"], "ok": True, "result": result}
                connection.sendall((json.dumps(reply) + "\n").encode())

    def close(self) -> None:
        self.server.close()


def main() -> int:
    cli = resolve_cmux_cli()
    failures: list[str] = []

    with tempfile.TemporaryDirectory(prefix="cmux-completion-") as temp:
        root = Path(temp)
        bin_dir = root / "bin"
        bin_dir.mkdir()
        (bin_dir / "cmux").symlink_to(cli)
        missing_socket = root / "missing.sock"
        env = {
            "HOME": str(root),
            "PATH": f"{bin_dir}:/usr/bin:/bin:/opt/homebrew/bin",
            "CMUX_SOCKET_PATH": str(missing_socket),
        }

        def complete(*words: str, socket_path: Path = missing_socket) -> list[str]:
            result = subprocess.run(
                [cli, "__complete", *words],
                env={**env, "CMUX_SOCKET_PATH": str(socket_path)},
                text=True,
                capture_output=True,
                timeout=10,
                check=False,
            )
            if result.returncode != 0:
                failures.append(f"__complete {words!r} exited {result.returncode}: {result.stderr}")
            return [line for line in result.stdout.splitlines() if line]

        # Command, subcommand, flag and global-option candidates.
        cases: list[tuple[tuple[str, ...], list[str], list[str]]] = [
            (("conf",), ["config"], []),
            (("--json", "conf"), ["config"], []),
            (("--socket", "/tmp/x.sock", "conf"), ["config"], []),
            (("--js",), ["--json"], []),
            (("config", ""), ["doctor", "validate", "path", "reload"], []),
            (("config", "va"), ["validate"], ["doctor"]),
            (("config", "validate", "--"), ["--path", "--scope", "--help"], []),
            (("canvas", ""), ["info", "mode", "align"], []),
            (("completion", ""), ["zsh", "bash", "fish"], []),
            (("", ), ["config", "completion", "workspace"], ["__complete", "__tmux-compat"]),
            (("no-such-command", ""), [], []),
        ]
        for words, required, forbidden in cases:
            got = complete(*words)
            missing = [item for item in required if item not in got]
            present = [item for item in forbidden if item in got]
            if missing or present:
                failures.append(f"__complete {words!r}: missing {missing}, unexpected {present}, got {got[:20]}")
        if complete("no-such-command", ""):
            failures.append("unknown command produced candidates; the shell would not fall back to files")

        # Live handles from the app over the socket.
        live_path = root / "live.sock"
        live = FakeCmuxSocket(live_path)
        try:
            handles = complete("send", "--workspace", "", socket_path=live_path)
            if handles != ["workspace:7", "workspace:8"]:
                failures.append(f"--workspace handles: {handles}")
            if live.methods != ["workspace.list"]:
                failures.append(f"fake socket saw {live.methods}, expected one workspace.list")
            if complete("send", "--workspace", "workspace:8", socket_path=live_path) != ["workspace:8"]:
                failures.append("--workspace prefix filtering failed")
        finally:
            live.close()

        stalled_path = root / "stalled.sock"
        stalled = FakeCmuxSocket(stalled_path, stall=True)
        try:
            started = time.monotonic()
            stalled_handles = complete("send", "--workspace", "", socket_path=stalled_path)
            elapsed = time.monotonic() - started
            if stalled_handles or elapsed > 3:
                failures.append(f"stalled socket: handles {stalled_handles} after {elapsed:.1f}s (must be empty and bounded)")
        finally:
            stalled.close()

        # Scripts parse in each shell and drive real completion.
        scripts: dict[str, str] = {}
        for shell in ("zsh", "bash", "fish"):
            result = subprocess.run([cli, "completion", shell], env=env, text=True, capture_output=True, check=False)
            if result.returncode != 0 or not result.stdout.strip():
                failures.append(f"completion {shell} exited {result.returncode}: {result.stderr}")
            scripts[shell] = result.stdout
        bad = subprocess.run([cli, "completion", "powershell"], env=env, text=True, capture_output=True, check=False)
        if bad.returncode != 2 or "zsh|bash|fish" not in bad.stderr:
            failures.append(f"unsupported shell: exit {bad.returncode}, stderr {bad.stderr!r}")

        bash = shutil.which("bash", path=env["PATH"])
        zsh = shutil.which("zsh", path=env["PATH"])
        fish = shutil.which("fish", path=env["PATH"])
        for name, path in (("bash", bash), ("zsh", zsh), ("fish", fish)):
            if path is None:
                failures.append(f"{name} is not installed, so its completion script is untested (brew install {name})")
                continue
            script_file = root / f"cmux.{name}"
            script_file.write_text(scripts[name])
            syntax = subprocess.run([path, "-n", str(script_file)], env=env, text=True, capture_output=True, check=False)
            if syntax.returncode != 0:
                failures.append(f"{name} -n rejected the script: {syntax.stderr}")

        live = FakeCmuxSocket(live_path.with_name("live2.sock"))
        live_env = {**env, "CMUX_SOCKET_PATH": str(live.path)}
        try:
            # macOS ships bash 3.2 as /bin/bash; Homebrew bash is 5.x. Both must work.
            bashes = sorted({path for path in (bash, "/bin/bash") if path and os.access(path, os.X_OK)})
            for bash in bashes:
                driver = (
                    f'source {root / "cmux.bash"}\n'
                    'for line in "cmux conf" "cmux config va" "cmux --json conf" "cmux send --workspace workspace:"; do\n'
                    '  COMP_LINE="$line"; COMP_POINT=${#line}; COMPREPLY=(); _cmux\n'
                    '  printf "%s=%s\\n" "$line" "${COMPREPLY[*]}"\n'
                    'done\n'
                )
                out = subprocess.run([bash, "--norc", "-c", driver], env=live_env, text=True, capture_output=True, check=False)
                expected = {
                    "cmux conf": "config",
                    "cmux config va": "validate",
                    "cmux --json conf": "config",
                    # bash splits words at ':', so candidates drop the typed prefix.
                    "cmux send --workspace workspace:": "7 8",
                }
                got = dict(line.split("=", 1) for line in out.stdout.splitlines() if "=" in line)
                if got != expected:
                    failures.append(f"{bash} completion: {got} (stderr {out.stderr!r}), expected {expected}")
            if zsh is not None:
                driver = (
                    'compdef() { :; }\n_files() { print -r -- FILES; }\n'
                    'compadd() { [[ $1 == -- ]] && shift; print -rl -- "$@"; }\n'
                    f'source {root / "cmux.zsh"}\n'
                    'words=(cmux config va); CURRENT=3; _cmux\n'
                    'words=(cmux no-such-command ""); CURRENT=3; _cmux\n'
                    'words=(cmux send --workspace ""); CURRENT=4; _cmux\n'
                )
                out = subprocess.run([zsh, "-f", "-c", driver], env=live_env, text=True, capture_output=True, check=False)
                if out.stdout.splitlines() != ["validate", "FILES", "workspace:7", "workspace:8"]:
                    failures.append(f"zsh completion: {out.stdout.splitlines()} (stderr {out.stderr!r})")
        finally:
            live.close()

    # Completion offers CMUXCLI.topLevelCommandNames; every command run()
    # dispatches must be in it (internal `__` commands excepted).
    repo = Path(__file__).resolve().parents[1]
    lines = (repo / "CLI" / "cmux.swift").read_text().split("\n")
    start = next(i for i, line in enumerate(lines) if re.match(r"\s*func run\(\) throws", line))
    switch = next(i for i in range(start, len(lines)) if lines[i].strip() == "switch command {")
    dispatched = set(re.findall(r'command == "([^"]+)"', "\n".join(lines[start:switch])))
    indent = re.match(r"\s*", lines[switch]).group(0)
    for line in lines[switch + 1 :]:
        if line.startswith(indent + "}"):
            break
        label = re.match(re.escape(indent) + r"case (.+):\s*$", line)
        if label:
            dispatched |= set(re.findall(r'"([^"]+)"', label.group(1)))
    suggestions = (repo / "CLI" / "CMUXCLI+CommandSuggestions.swift").read_text()
    listed = set(re.findall(r'"([^"]+)"', suggestions[suggestions.index("static let topLevelCommandNames"):].split("]")[0]))
    unlisted = sorted(name for name in dispatched - listed if not name.startswith("__"))
    if len(dispatched) < 100:
        failures.append(f"parsed only {len(dispatched)} dispatched commands from run(); the parser is stale")
    if unlisted:
        failures.append(f"commands run() dispatches but completion never offers: {unlisted}")

    if failures:
        print("FAIL: cmux shell completion")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print("PASS: cmux shell completion")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
