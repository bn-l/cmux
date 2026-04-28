#!/usr/bin/env python3
"""
Pre-implementation regression suite for memory_leak2.md hibernation work.

This file is intentionally standalone: run only this test file when working on
the renderer-hibernation plan. It avoids UI automation and screenshots. The
tests drive cmux through the socket/debug harness and the app runtime itself.

The suite focuses on code the hibernation plan will touch:
  - hidden workspace terminal/io behavior
  - terminal portal visibility churn
  - Ghostty appearance/config propagation across hidden surfaces
  - socket hot paths that must not block on main
  - process resource counters that reveal renderer/thread/FD leaks

These tests must hard-fail if their harness is unavailable. A skip would give
false confidence before a high-risk renderer lifecycle change.
"""
from __future__ import annotations

import os
import re
import shlex
import socket
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import uuid
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from cmux import cmux, cmuxError  # type: ignore


MIN_SURFACES = 3
APPEARANCE_SURFACES = 5
MAX_PORTAL_DEPTH = 8
RUN_ID = f"{os.getpid()}_{uuid.uuid4().hex[:8]}"


def _command_output(argv: list[str], *, timeout: float = 10.0) -> str:
    try:
        proc = subprocess.run(
            argv,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as exc:
        raise AssertionError(f"{argv[0]} failed: {exc}") from exc
    if proc.returncode != 0:
        raise AssertionError(
            f"{' '.join(argv)} exited {proc.returncode}:\n{proc.stdout[-2000:]}"
        )
    return proc.stdout


def _parse_size_bytes(value: str, unit: str) -> int:
    multiplier = {
        "K": 1024,
        "M": 1024 * 1024,
        "G": 1024 * 1024 * 1024,
    }[unit.upper()]
    return int(float(value) * multiplier)


def _debug_pid(client: cmux) -> int:
    response = client._send_command("debug_pid")
    if not response.startswith("OK "):
        raise AssertionError(
            "debug_pid is required for this suite. Run against a tagged DEBUG "
            f"cmux build, not production. Response: {response}"
        )
    return int(response[3:].strip())


def _thread_count(pid: int) -> int:
    output = _command_output(["ps", "-M", str(pid)], timeout=10.0)
    lines = [line for line in output.splitlines() if line.strip()]
    if len(lines) < 2:
        raise AssertionError(f"ps -M returned no thread rows for pid={pid}:\n{output}")
    return len(lines) - 1


def _fd_count(pid: int) -> int:
    output = _command_output(["lsof", "-p", str(pid)], timeout=10.0)
    lines = [line for line in output.splitlines() if line.strip()]
    if len(lines) < 2:
        raise AssertionError(f"lsof returned no fd rows for pid={pid}:\n{output}")
    return len(lines) - 1


def _iosurface_bytes(pid: int) -> int:
    output = _command_output(["vmmap", "--summary", str(pid)], timeout=20.0)
    match = re.search(r"^IOSurface\s+([0-9.]+)([KMG])\b", output, re.MULTILINE)
    if not match:
        raise AssertionError(f"vmmap summary did not contain IOSurface row:\n{output[-4000:]}")
    return _parse_size_bytes(match.group(1), match.group(2))


def _socket_health(client: cmux) -> dict[str, int]:
    response = client._send_command("socket_health")
    if response.startswith("ERROR"):
        raise AssertionError(f"socket_health failed: {response}")
    return {
        key: int(value)
        for key, value in (
            token.split("=", 1)
            for token in response.split()
            if "=" in token
        )
    }


def _send_workspace(client: cmux, workspace_id: str, text: str) -> None:
    escaped = text.replace("\n", "\\n").replace("\r", "\\r").replace("\t", "\\t")
    response = client._send_command(f"send_workspace {workspace_id} {escaped}")
    if not response.startswith("OK"):
        raise cmuxError(response)


def _raw_socket() -> socket.socket:
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    sock.settimeout(3.0)
    sock.connect(cmux.default_socket_path())
    return sock


def _send_raw_line(sock: socket.socket, command: str) -> str:
    sock.sendall((command + "\n").encode("utf-8"))
    chunks: list[bytes] = []
    while True:
        chunk = sock.recv(4096)
        if not chunk:
            break
        chunks.append(chunk)
        if b"\n" in chunk:
            break
    data = b"".join(chunks).split(b"\n", 1)[0]
    return data.decode("utf-8", errors="replace")


def _wait_until(predicate, *, timeout: float, interval: float = 0.05, label: str) -> None:
    deadline = time.monotonic() + timeout
    last_exc: Exception | None = None
    while time.monotonic() < deadline:
        try:
            if predicate():
                return
        except Exception as exc:  # noqa: BLE001 - preserve last failure for message
            last_exc = exc
        time.sleep(interval)
    suffix = f" Last exception: {last_exc}" if last_exc else ""
    raise AssertionError(f"timed out waiting for {label}.{suffix}")


def _wait_for_text(client: cmux, panel_id: str, marker: str, *, timeout: float = 5.0) -> None:
    def has_marker() -> bool:
        return marker in client.read_terminal_text(panel_id)

    _wait_until(has_marker, timeout=timeout, label=f"terminal text marker {marker}")


class HibernationPreflightCase(unittest.TestCase):
    def setUp(self) -> None:
        self.client = cmux()
        self.client.connect()
        _debug_pid(self.client)
        self.workspaces: list[str] = []

    def tearDown(self) -> None:
        try:
            self.client.debug_set_applicator_slow_ms(0)
        except Exception:
            pass
        try:
            self.client._send_command("debug_force_appearance reset")
        except Exception:
            pass
        try:
            self.client.debug_reset_appearance_log()
        except Exception:
            pass
        for workspace_id in reversed(self.workspaces):
            try:
                self.client.close_workspace(workspace_id)
                self.client.debug_notification_drain()
                time.sleep(0.1)
            except Exception:
                pass
        self.client.close()

    def make_workspace(self, *, surfaces: int = 1) -> str:
        workspace_id = self.client.new_workspace()
        self.workspaces.append(workspace_id)
        # `new_workspace` is intentionally not a focus-intent socket command.
        # Select explicitly so subsequent split/send/read operations target
        # the workspace this test owns instead of mutating the prior workspace.
        self.client.select_workspace(workspace_id)
        time.sleep(0.25)
        self.ensure_surface_count(surfaces)
        self.client.debug_notification_drain()
        self.assert_terminal_portals_healthy(expected_min=surfaces)
        return workspace_id

    def select_workspace_and_wait(self, workspace_id: str, *, expected_min: int = 1) -> None:
        self.client.select_workspace(workspace_id)
        self.client.debug_notification_drain()
        self.assert_terminal_portals_healthy(expected_min=expected_min)

    def ensure_surface_count(self, count: int) -> list[tuple[int, str, bool]]:
        attempts = 0
        while len(self.client.list_surfaces()) < count and attempts < count * 3:
            direction = "right" if attempts % 2 == 0 else "down"
            self.client.new_split(direction)
            time.sleep(0.25)
            attempts += 1
        surfaces = self.client.list_surfaces()
        if len(surfaces) < count:
            raise AssertionError(f"expected {count} surfaces, got {len(surfaces)}: {surfaces}")
        return surfaces

    def assert_terminal_portals_healthy(self, *, expected_min: int = 1) -> None:
        last_rows: list[dict] = []

        def healthy() -> bool:
            nonlocal last_rows
            rows = self.client.surface_health()
            last_rows = rows
            terminals = [row for row in rows if row.get("type") == "terminal"]
            if len(terminals) < expected_min:
                return False
            for row in terminals:
                if row.get("in_window") is not True:
                    return False
                if row.get("portal") is not True:
                    return False
                depth = row.get("view_depth")
                if not isinstance(depth, int) or depth > MAX_PORTAL_DEPTH:
                    return False
            return True

        _wait_until(
            healthy,
            timeout=5.0,
            label=(
                f"{expected_min} healthy portal-hosted terminal surfaces; "
                f"last_rows={last_rows}"
            ),
        )

    def wait_for_shell_ready(self, surface_id: str, marker_prefix: str) -> str:
        """Prove the target shell is accepting input before the real assertion."""
        marker = f"{marker_prefix}_{RUN_ID}"
        last_failure: Exception | None = None
        for _ in range(3):
            try:
                self.client.send_key_surface(surface_id, "ctrl-c")
            except Exception as exc:  # noqa: BLE001 - preserve detail for final failure
                last_failure = exc
            time.sleep(0.25)
            self.client.send_surface(surface_id, f"printf '{marker}\\n'\n")
            try:
                _wait_for_text(self.client, surface_id, marker, timeout=5.0)
                return marker
            except AssertionError as exc:
                last_failure = exc
        raise AssertionError(
            f"terminal shell did not become ready on surface {surface_id}: {last_failure}"
        )

    def force_appearance_and_wait(self, scheme: str, *, timeout: float = 5.0) -> None:
        """Force light/dark and wait until every live surface reports that scheme."""
        self.assertEqual(self.client._send_command(f"debug_force_appearance {scheme}"), "OK")

        def all_scheme() -> bool:
            self.client.debug_notification_drain()
            dump = self.client.debug_dump_appearance_log()
            return bool(dump["surfaces"]) and all(
                row["scheme"] == scheme for row in dump["surfaces"]
            )

        _wait_until(all_scheme, timeout=timeout, label=f"all surfaces reaching {scheme} appearance")


class TestHiddenTerminalIO(HibernationPreflightCase):
    def test_hidden_workspace_output_does_not_block_pty_writer(self) -> None:
        """A hidden terminal must keep draining PTY output.

        The future hibernation code may remove the renderer, but it must not
        pause Termio/io. The command writes enough stdout to exceed a small PTY
        buffer, then writes a done file. If hidden io stops draining, the Python
        child blocks before the file write while the workspace is hidden.
        """
        workspace_a = self.make_workspace(surfaces=1)
        surface_id = self.client.list_surfaces()[0][1]
        marker = f"CMUX_HIB_PRE_HIDDEN_IO_{RUN_ID}"
        script_file = Path(tempfile.gettempdir()) / f"{marker}.py"
        start_file = Path(tempfile.gettempdir()) / f"{marker}.started"
        done_file = Path(tempfile.gettempdir()) / f"{marker}.done"
        script_file.unlink(missing_ok=True)
        start_file.unlink(missing_ok=True)
        done_file.unlink(missing_ok=True)
        self.wait_for_shell_ready(surface_id, "CMUX_HIB_PRE_READY")

        # Arrange: start a child that floods stdout and writes a marker file
        # only after stdout has drained.
        script_file.write_text(f"""
import pathlib
import time

m = {marker!r}
pathlib.Path({str(start_file)!r}).write_text("started")
time.sleep(0.3)
for i in range(1200):
    print(f"{{m}}_LINE_{{i:04d}} " + "x" * 120, flush=True)
print({(marker + "_END")!r}, flush=True)
pathlib.Path({str(done_file)!r}).write_text("done")
""")
        self.client.send_surface(surface_id, f"python3 -u {shlex.quote(str(script_file))}\n")
        _wait_until(
            start_file.exists,
            timeout=5.0,
            interval=0.05,
            label="hidden PTY writer start marker",
        )

        # Act: immediately hide the workspace behind another workspace.
        workspace_b = self.make_workspace(surfaces=1)

        # Assert: the child completes while still hidden. This is the key
        # invariant for hibernation: PTY/io must stay alive without a renderer.
        _wait_until(
            done_file.exists,
            timeout=15.0,
            interval=0.1,
            label="hidden PTY writer completion marker",
        )
        self.assertEqual(
            self.client.current_workspace(),
            workspace_b,
            "hidden terminal output must not steal workspace selection",
        )

        self.select_workspace_and_wait(workspace_a, expected_min=1)
        _wait_for_text(self.client, surface_id, f"{marker}_END", timeout=5.0)
        script_file.unlink(missing_ok=True)
        start_file.unlink(missing_ok=True)
        done_file.unlink(missing_ok=True)

    def test_send_workspace_to_hidden_terminal_preserves_state_and_focus(self) -> None:
        """The control socket can send to a hidden workspace without selecting it.

        Hibernation will add wake/hibernate state around visibility transitions;
        this locks in that hidden workspaces still accept input and preserve
        their selected terminal until the user returns.
        """
        workspace_a = self.make_workspace(surfaces=MIN_SURFACES)
        surfaces = self.client.list_surfaces()
        target_id = surfaces[0][1]
        self.client.focus_surface(target_id)
        pre_marker = f"CMUX_HIB_PRE_VISIBLE_{RUN_ID}"
        hidden_marker = f"CMUX_HIB_PRE_SOCKET_HIDDEN_{RUN_ID}"

        self.wait_for_shell_ready(target_id, "CMUX_HIB_PRE_FOCUS_READY")
        self.client.send_surface(target_id, f"printf '{pre_marker}\\n'\n")
        _wait_for_text(self.client, target_id, pre_marker)

        workspace_b = self.make_workspace(surfaces=1)
        _send_workspace(self.client, workspace_a, f"printf '{hidden_marker}\\n'\n")
        time.sleep(0.5)
        self.assertEqual(
            self.client.current_workspace(),
            workspace_b,
            "send_workspace to a hidden terminal must not select that workspace",
        )

        self.select_workspace_and_wait(workspace_a, expected_min=MIN_SURFACES)
        refreshed_surfaces = self.client.list_surfaces()
        selected_ids = [surface_id for _, surface_id, selected in refreshed_surfaces if selected]
        self.assertIn(
            target_id,
            selected_ids,
            f"hidden workspace input changed selected surface: {refreshed_surfaces}",
        )
        _wait_for_text(self.client, target_id, pre_marker)
        _wait_for_text(self.client, target_id, hidden_marker)


class TestVisibilityAndResourceChurn(HibernationPreflightCase):
    def test_workspace_visibility_churn_keeps_surface_ids_portals_and_resources_stable(self) -> None:
        """Repeated hide/reveal cycles must not detach terminals or leak resources.

        This is the non-UI wake/hide regression fence for the future automatic
        hibernation policy. It uses socket selection only, then inspects portal
        health, surface identity, process threads, FDs, and IOSurface bytes.
        """
        pid = _debug_pid(self.client)
        workspace_a = self.make_workspace(surfaces=MIN_SURFACES)
        surface_ids = [surface_id for _, surface_id, _ in self.client.list_surfaces()]
        self.assert_terminal_portals_healthy(expected_min=MIN_SURFACES)

        workspace_b = self.make_workspace(surfaces=MIN_SURFACES)
        workspace_c = self.make_workspace(surfaces=1)

        self.select_workspace_and_wait(workspace_a, expected_min=MIN_SURFACES)
        baseline_threads = _thread_count(pid)
        baseline_fds = _fd_count(pid)
        baseline_iosurface = _iosurface_bytes(pid)

        # Act: churn the exact visibility paths hibernation will hook.
        for _ in range(8):
            for workspace_id in (workspace_b, workspace_c, workspace_a):
                self.client.select_workspace(workspace_id)
                self.client.debug_notification_drain()
                time.sleep(0.05)

        self.select_workspace_and_wait(workspace_a, expected_min=MIN_SURFACES)

        # Assert: surface identity and terminal responsiveness survived.
        current_ids = [surface_id for _, surface_id, _ in self.client.list_surfaces()]
        self.assertEqual(current_ids, surface_ids)
        for surface_id in surface_ids:
            self.wait_for_shell_ready(surface_id, f"CMUX_HIB_PRE_CHURN_READY_{surface_id[:8]}")
            marker = f"CMUX_HIB_PRE_CHURN_{RUN_ID}_{surface_id[:8]}"
            self.client.send_surface(surface_id, f"printf '{marker}\\n'\n")
            _wait_for_text(self.client, surface_id, marker, timeout=5.0)

        # Assert: no unbounded process resource growth. Allow slack for
        # AppKit/GCD caches and transient renderer work, but catch true leaks.
        post_threads = _thread_count(pid)
        post_fds = _fd_count(pid)
        post_iosurface = _iosurface_bytes(pid)
        self.assertLessEqual(
            post_threads - baseline_threads,
            32,
            f"thread growth after visibility churn: baseline={baseline_threads} post={post_threads}",
        )
        self.assertLessEqual(
            post_fds - baseline_fds,
            32,
            f"FD growth after visibility churn: baseline={baseline_fds} post={post_fds}",
        )
        self.assertLessEqual(
            post_iosurface - baseline_iosurface,
            128 * 1024 * 1024,
            "IOSurface bytes grew too much after visibility churn: "
            f"baseline={baseline_iosurface} post={post_iosurface}",
        )


class TestAppearanceAndReloadInvariants(HibernationPreflightCase):
    def test_hidden_surfaces_receive_chunked_appearance_without_app_reload_fanout(self) -> None:
        """Hidden-surface theme propagation must stay chunked and surface-scoped.

        This locks in the DEVLOG fixes that hibernation will sit next to:
        hidden surfaces must converge on the final scheme, the sweep must be
        chunked enough to avoid main starvation, and appearance propagation must
        not regress to app-wide Ghostty reload fanout.
        """
        workspace_a = self.make_workspace(surfaces=MIN_SURFACES)
        self.make_workspace(surfaces=1)  # hide workspace_a
        self.client.debug_notification_drain()
        time.sleep(0.3)

        self.force_appearance_and_wait("light")
        self.client.debug_reset_appearance_log()
        self.client.debug_reset_reload_counters()
        self.client.debug_set_sweep_chunk_size(1)
        self.client.debug_set_applicator_slow_ms(25)
        baseline = self.client.debug_reload_counters()

        self.force_appearance_and_wait("dark")
        dump = self.client.debug_dump_appearance_log()
        final = self.client.debug_reload_counters()

        dark_chunks = [chunk for chunk in dump["chunks"] if chunk["scheme"] == "dark"]
        self.assertGreaterEqual(
            len(dark_chunks),
            MIN_SURFACES,
            f"appearance sweep did not chunk hidden surfaces enough: {dump}",
        )
        self.assertEqual(
            final["app"] - baseline["app"],
            0,
            f"appearance propagation regressed to app reload fanout: baseline={baseline} final={final}",
        )
        self.assertGreaterEqual(
            final["surface"] - baseline["surface"],
            MIN_SURFACES,
            f"surface reload path did not run; test would be vacuous: baseline={baseline} final={final}",
        )

        self.select_workspace_and_wait(workspace_a, expected_min=MIN_SURFACES)

    def test_chunked_appearance_keeps_main_loop_responsive(self) -> None:
        """A slow chunked sweep must still let unrelated main work run."""
        self.make_workspace(surfaces=APPEARANCE_SURFACES)
        self.force_appearance_and_wait("light")
        self.client.debug_reset_appearance_log()
        self.client.debug_set_sweep_chunk_size(1)
        slow_ms = 40
        self.client.debug_set_applicator_slow_ms(slow_ms)

        samples_ms: list[float] = []
        probe_errors: list[str] = []
        stop = threading.Event()
        reset_probe_clock = threading.Event()

        def probe_main_queue() -> None:
            try:
                sock = _raw_socket()
            except Exception as exc:  # noqa: BLE001 - reported after join
                probe_errors.append(f"main-loop probe failed to connect: {exc}")
                return
            with sock:
                prev = time.monotonic()
                while not stop.is_set():
                    response = _send_raw_line(sock, "debug_notification_drain")
                    if response != "OK":
                        probe_errors.append(f"debug_notification_drain failed: {response}")
                        return
                    now = time.monotonic()
                    if reset_probe_clock.is_set():
                        prev = now
                        reset_probe_clock.clear()
                    else:
                        samples_ms.append((now - prev) * 1000.0)
                    prev = now
                    time.sleep(0.005)

        thread = threading.Thread(target=probe_main_queue, daemon=True)
        thread.start()
        try:
            time.sleep(0.1)
            samples_ms.clear()
            reset_probe_clock.set()
            self.force_appearance_and_wait("dark")
        finally:
            stop.set()
            thread.join(timeout=2.0)

        dump = self.client.debug_dump_appearance_log()
        dark_chunks = [chunk for chunk in dump["chunks"] if chunk["scheme"] == "dark"]
        self.assertGreaterEqual(
            len(dark_chunks),
            APPEARANCE_SURFACES,
            f"liveness test did not exercise a chunked sweep: {dump}",
        )
        self.assertFalse(probe_errors, probe_errors)
        self.assertGreater(len(samples_ms), 5, f"main-loop probe starved: {samples_ms}")
        self.assertLess(
            max(samples_ms),
            slow_ms * 3,
            f"main loop was starved behind the whole sweep: {samples_ms}",
        )


class TestSocketHotPaths(HibernationPreflightCase):
    def test_report_ports_and_ports_kick_do_not_block_behind_main(self) -> None:
        """Telemetry hot paths must remain off-main/fire-and-forget.

        Hibernation will add more debug/status socket work. This guards the
        recent rule from CLAUDE.md and DEVLOG: report_* and ports_kick must not
        park socket handler threads behind a stalled main queue.
        """
        workspace_id = self.make_workspace(surfaces=1)
        panel_id = self.client.list_surfaces()[0][1]
        baseline = _socket_health(self.client)

        self.assertEqual(self.client._send_command("debug_block_main_ms 700"), "OK")
        start = time.monotonic()
        with _raw_socket() as sock:
            for i in range(60):
                port = 20000 + (i % 1000)
                for command in (
                    f"report_ports {port} --tab={workspace_id} --panel={panel_id}",
                    f"ports_kick --tab={workspace_id} --panel={panel_id}",
                    f"clear_ports --tab={workspace_id} --panel={panel_id}",
                ):
                    response = _send_raw_line(sock, command)
                    if not response.startswith("OK"):
                        raise AssertionError(f"{command} failed: {response}")
        elapsed_ms = (time.monotonic() - start) * 1000.0

        self.assertLess(
            elapsed_ms,
            1200,
            f"telemetry hot paths blocked behind main for {elapsed_ms:.0f}ms",
        )
        time.sleep(0.9)
        self.client.debug_notification_drain()
        final = _socket_health(self.client)
        self.assertEqual(
            final["current"],
            baseline["current"],
            f"socket permits leaked after telemetry burst: baseline={baseline} final={final}",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
