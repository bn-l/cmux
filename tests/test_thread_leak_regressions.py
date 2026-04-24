"""
Regression tests for PLAN_thread_leak.md.

These tests exercise the fire-and-forget notification contract (Phase 3),
the SocketHandlerLimiter cap (Phase 4), and the chunked appearance sweep
(Phase 5). They run against a tagged DEBUG build's socket; the DEBUG-only
harness commands used here (`debug_notification_drain`, `debug_block_main_ms`,
`debug_force_appearance`, `debug_set_applicator_slow_ms`,
`debug_dump_appearance_log`, `debug_pid`) are gated on #if DEBUG in
TerminalController.swift and will fail with "ERROR: Unknown command" on
production builds.

Per cmux/CLAUDE.md "Testing policy": tests never run locally. CI/VM entry
points that pick this file up:
  - ``.github/workflows/ci.yml`` ``tests-build-and-lag`` job adds a
    "Run thread-leak regressions" step that launches a tagged cmux DEV and
    invokes ``python3 tests/test_thread_leak_regressions.py``.
  - The VM runner ``scripts/run-tests-v1.sh`` picks this file up via its
    ``tests/test_*.py`` glob.
Do NOT edit the docstring to claim ``gh workflow run test-e2e.yml`` runs this;
that workflow runs Xcode UI tests only.
"""
from __future__ import annotations

import os
import socket
import subprocess
import threading
import time
import unittest

from cmux import cmux, cmuxError  # type: ignore


def _cmux_pid(client: cmux) -> int | None:
    """Return the cmux process PID via the DEBUG-only debug_pid command.
    Returns None on production builds where the command is gated off.
    """
    response = client._send_command("debug_pid")
    if not response.startswith("OK "):
        return None
    try:
        return int(response[3:].strip())
    except ValueError:
        return None


def _thread_count(pid: int) -> int | None:
    """Best-effort thread count via `ps -M <pid> | wc -l`. Returns None if we
    cannot sample (e.g. SIP or pid gone)."""
    try:
        out = subprocess.check_output(
            ["ps", "-M", str(pid)], stderr=subprocess.DEVNULL
        )
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return None
    lines = [ln for ln in out.decode("utf-8", errors="replace").splitlines() if ln.strip()]
    # First line is a header; each subsequent line is one thread.
    return max(0, len(lines) - 1)


def _fd_count(pid: int) -> int | None:
    """Best-effort open-fd count via `lsof -p <pid>`."""
    try:
        out = subprocess.check_output(
            ["lsof", "-p", str(pid)], stderr=subprocess.DEVNULL
        )
    except (subprocess.CalledProcessError, FileNotFoundError, OSError):
        return None
    lines = [ln for ln in out.decode("utf-8", errors="replace").splitlines() if ln.strip()]
    return max(0, len(lines) - 1)


def _parse_socket_health(line: str) -> dict:
    parts = dict(tok.split("=", 1) for tok in line.split() if "=" in tok)
    return {
        "cap": int(parts.get("cap", "0")),
        "current": int(parts.get("current", "0")),
        "peak": int(parts.get("peak", "0")),
        "rejected": int(parts.get("rejected", "0")),
    }


class TestFireAndForgetNotifications(unittest.TestCase):
    def setUp(self) -> None:
        self.client = cmux()
        self.client.connect()
        self.client.clear_notifications()

    def tearDown(self) -> None:
        try:
            self.client.clear_notifications()
        finally:
            self.client.close()

    def test_list_after_clear_drain_reads_empty(self) -> None:
        """Even under fire-and-forget, helper-based read-after-write works."""
        self.client.notify("t1", body="b1")
        self.client.notify("t2", body="b2")
        items = self.client.list_notifications()
        self.assertEqual(len(items), 2)
        self.client.clear_notifications()
        items = self.client.list_notifications()
        self.assertEqual(items, [])

    def test_list_without_drain_is_eventually_consistent(self) -> None:
        """wait_for_notifications_eventually must converge within timeout."""
        self.client.notify("x", body="y")
        items = self.client.wait_for_notifications_eventually(
            lambda xs: len(xs) >= 1, timeout=1.0,
        )
        self.assertTrue(len(items) >= 1)


class TestSocketHealth(unittest.TestCase):
    """Phase 4: socket_health reports metrics without blocking main."""

    def test_socket_health_returns_metrics_line(self) -> None:
        with cmux() as client:
            response = client._send_command("socket_health")
            self.assertFalse(response.startswith("ERROR"))
            # Shape: "cap=N current=N peak=N rejected=N"
            for key in ("cap=", "current=", "peak=", "rejected="):
                self.assertIn(key, response)


class TestNotificationBurstUnderMainBlock(unittest.TestCase):
    """Phase 6.3 shape: fire many notification commands over one persistent
    socket while main is blocked. Handlers must return quickly (fire-and-forget);
    this alone does NOT exercise SocketHandlerLimiter cap/peak/rejected because
    the whole burst runs on a single accept-handler thread — see
    ``TestSocketHandlerLimiterUnderConcurrentConnections`` for the concurrent
    limiter coverage.
    """

    def test_notify_target_burst_under_main_block(self) -> None:
        with cmux() as client:
            block_ms = 500
            # Kick a main block that lasts 500ms.
            self.assertEqual(
                client._send_command(f"debug_block_main_ms {block_ms}"),
                "OK",
            )

            start = time.monotonic()
            # Fire 50 clear_notifications while main is blocked. Each should
            # return quickly because the clear is now fire-and-forget.
            for _ in range(50):
                # We don't care about the result, just the latency.
                client._send_command("clear_notifications")
            elapsed_ms = (time.monotonic() - start) * 1000

            # With the old .sync contract these would block ~= block_ms each.
            # With fire-and-forget each returns in well under the block duration,
            # so the whole batch completes comfortably within one block-duration
            # window plus slack.
            self.assertLess(
                elapsed_ms, block_ms + 1500,
                f"burst took {elapsed_ms:.0f}ms — fire-and-forget regressed?",
            )

            # Let the main block drain.
            time.sleep((block_ms / 1000.0) + 0.5)
            client.debug_notification_drain()


class TestSocketHandlerLimiterUnderConcurrentConnections(unittest.TestCase):
    """Phase 4 + Phase 6: fire many concurrent independent socket connections
    (more than the limiter cap) and assert:

      - peak_inflight never exceeds cap (the limiter is not leaky).
      - rejected increases OR every over-cap client sees ``server_busy`` (the
        reject path fires when the cap is saturated).
      - After all clients disconnect, ``current`` returns to the pre-burst
        baseline (NOT zero — the admin socket still holds its own permit
        for the entire handler-thread lifetime; see
        ``TerminalController.swift`` ``handlerLimiter.tryAcquire`` /
        ``defer { limiter.release() }``).
      - Process FD/thread counts (best-effort) stay bounded and return close
        to baseline.
    """

    BASELINE_DRAIN_S = 0.5
    HOLD_DURATION_S = 0.6

    def _open_socket(self) -> socket.socket:
        path = cmux.default_socket_path()
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(2.0)
        s.connect(path)
        return s

    def _drain_socket(self, sock: socket.socket, budget_s: float = 0.1) -> bytes:
        """Read whatever the server sent (e.g. ``ERROR: server_busy\\n``) without
        blocking forever."""
        data = b""
        end = time.monotonic() + budget_s
        sock.settimeout(0.05)
        while time.monotonic() < end:
            try:
                chunk = sock.recv(1024)
            except socket.timeout:
                break
            except OSError:
                break
            if not chunk:
                break
            data += chunk
        return data

    def test_concurrent_connection_burst_respects_limiter(self) -> None:
        admin = cmux()
        admin.connect()
        try:
            self._run_concurrent_burst(admin)
        finally:
            admin.close()

    def _run_concurrent_burst(self, admin: cmux) -> None:
        baseline_metrics = _parse_socket_health(admin._send_command("socket_health"))
        cap = baseline_metrics["cap"]
        self.assertGreater(cap, 0)

        # The admin connection itself holds exactly one permit for the entire
        # session (see TerminalController.swift: handlerLimiter.tryAcquire is
        # paired with `defer { limiter.release() }` scoped to the handler
        # thread). So `baseline_current` is the floor we expect the limiter
        # to return to after the burst drains — not zero.
        baseline_current = baseline_metrics["current"]
        self.assertGreaterEqual(
            baseline_current, 1,
            "admin socket should occupy at least its own permit: "
            f"{baseline_metrics}",
        )

        # Reset peak/rejected. There's no explicit reset command — capture
        # deltas instead.
        baseline_rejected = baseline_metrics["rejected"]

        pid = _cmux_pid(admin)
        baseline_threads = _thread_count(pid) if pid is not None else None
        baseline_fds = _fd_count(pid) if pid is not None else None

        # Keep main blocked for most of the test so commands the accepted
        # handlers issue stay queued — this maximises the chance of
        # concurrent accepted handlers coexisting. Block for longer than
        # HOLD_DURATION_S so it doesn't lift mid-test.
        block_ms = int(self.HOLD_DURATION_S * 1000) + 400
        self.assertEqual(
            admin._send_command(f"debug_block_main_ms {block_ms}"), "OK",
        )

        # Fire N > cap connections truly in parallel via threads.
        n_connections = cap + 32  # guaranteed over-cap
        accepted_sockets: list[socket.socket] = []
        accepted_lock = threading.Lock()
        rejected_seen = 0
        rejected_lock = threading.Lock()

        def open_and_hold() -> None:
            nonlocal rejected_seen
            try:
                sock = self._open_socket()
            except OSError:
                return
            greeting = self._drain_socket(sock, budget_s=0.05)
            if b"server_busy" in greeting:
                with rejected_lock:
                    rejected_seen += 1
                sock.close()
                return
            # Accepted: keep the handler thread alive.
            with accepted_lock:
                accepted_sockets.append(sock)

        threads = [
            threading.Thread(target=open_and_hold, daemon=True)
            for _ in range(n_connections)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join(timeout=self.HOLD_DURATION_S + 1.0)

        # Admin can still talk to the socket because its accept happened
        # before the burst (persistent connection).
        mid = _parse_socket_health(admin._send_command("socket_health"))

        peak_threads = _thread_count(pid) if pid is not None else None
        peak_fds = _fd_count(pid) if pid is not None else None

        # Close everything.
        with accepted_lock:
            for sock in accepted_sockets:
                try:
                    sock.close()
                except OSError:
                    pass
            accepted_count = len(accepted_sockets)
            accepted_sockets.clear()

        # Let the accept loop and handlers wind down.
        time.sleep(self.BASELINE_DRAIN_S)
        admin.debug_notification_drain()
        final = _parse_socket_health(admin._send_command("socket_health"))

        # --- Core limiter assertions ---
        self.assertLessEqual(
            mid["peak"], cap,
            f"peak inflight {mid['peak']} exceeded cap {cap}: {mid}",
        )

        # Either the server reported rejected, or clients saw server_busy.
        # We require at least one path to fire since we deliberately exceeded
        # the cap.
        rejected_delta = final["rejected"] - baseline_rejected
        self.assertGreater(
            rejected_delta + rejected_seen, 0,
            f"nothing rejected despite {n_connections} > cap {cap}; "
            f"rejected_delta={rejected_delta} rejected_seen={rejected_seen} "
            f"mid={mid} final={final}",
        )

        # No permit leak after drain. Admin still holds its own permit, so
        # `current` should return to the pre-burst baseline, NOT to zero.
        self.assertEqual(
            final["current"], baseline_current,
            f"permits leaked after drain: baseline_current={baseline_current} "
            f"final={final}",
        )

        # Accepted count must not exceed cap minus the admin's permit. There
        # are only `cap - baseline_current` slots available for new clients
        # while admin is connected.
        available_cap = cap - baseline_current
        self.assertLessEqual(
            accepted_count, available_cap,
            f"accepted {accepted_count} exceeds available cap "
            f"{available_cap} (cap={cap} baseline={baseline_current})",
        )

        # --- FD / thread bounds (best-effort, skip if sampling failed) ---
        if baseline_threads is not None and peak_threads is not None:
            # Peak threads may grow by up to cap socket handler threads plus
            # slack (~64 for runloops/autorelease). Generous slack to avoid
            # flakes on busy VMs.
            thread_growth = peak_threads - baseline_threads
            self.assertLess(
                thread_growth, cap + 128,
                f"thread count exploded: baseline={baseline_threads} "
                f"peak={peak_threads} growth={thread_growth} cap={cap}",
            )

            # After drain, thread count should come back within a small delta
            # of baseline. Allow +32 for NSThread/GCD caching that doesn't
            # retire immediately.
            post_threads = _thread_count(pid)
            if post_threads is not None:
                self.assertLess(
                    post_threads - baseline_threads, 64,
                    f"threads leaked: baseline={baseline_threads} "
                    f"post={post_threads}",
                )

        if baseline_fds is not None and peak_fds is not None:
            fd_growth = peak_fds - baseline_fds
            # Accepted sockets each hold one server-side FD plus one client
            # side FD in the same process (none — client is this process).
            # Allow cap + slack for logs and transient state.
            self.assertLess(
                fd_growth, cap + 128,
                f"fd count exploded: baseline={baseline_fds} "
                f"peak={peak_fds} cap={cap}",
            )

            post_fds = _fd_count(pid)
            if post_fds is not None:
                self.assertLess(
                    post_fds - baseline_fds, 32,
                    f"fds leaked: baseline={baseline_fds} post={post_fds}",
                )


class TestAppearanceForceReset(unittest.TestCase):
    """Phase 6.1 minimal harness test: exercise debug_force_appearance
    round-trip and ensure reset leaves the app unmodified.
    """

    def test_force_light_then_reset(self) -> None:
        client = cmux()
        client.connect()
        try:
            self.assertEqual(
                client._send_command("debug_force_appearance light"), "OK",
            )
            client.debug_notification_drain()  # run-loop barrier
            self.assertEqual(
                client._send_command("debug_force_appearance dark"), "OK",
            )
            client.debug_notification_drain()
        finally:
            # MUST reset or the app stays stuck forcing an appearance.
            try:
                self.assertEqual(
                    client._send_command("debug_force_appearance reset"), "OK",
                )
            finally:
                client.close()


class TestAppearanceChunkedSweepRegression(unittest.TestCase):
    """Phase 6.2: verify the chunked color-scheme sweep actually chunks, that a
    newer sweep supersedes an older one via the generation token, and that all
    surfaces converge on the final scheme.

    Harness requirements (DEBUG-only):
      - ``debug_set_applicator_slow_ms`` pads each applicator call so the sweep
        spans multiple run-loop ticks.
      - ``debug_dump_appearance_log`` returns the per-chunk event log and the
        per-surface ``lastAppliedColorScheme`` state so we can assert shape
        without racing the run loop.

    This is a behavioural, not shape, test: if the sweep regresses to a single
    synchronous fan-out, ``chunks`` will contain one event; if the generation
    token breaks, the older gen's chunks won't be marked aborted=1.
    """

    MIN_SURFACES = 3

    def setUp(self) -> None:
        self.client = cmux()
        self.client.connect()
        # Make sure nothing is left over from a prior run.
        self.client.debug_reset_appearance_log()
        # Force tiny chunks so the test exercises multi-chunk dispatch and
        # the generation-abort path without needing >8 live surfaces. The
        # debug_reset_appearance_log call in tearDown restores the default.
        self.client.debug_set_sweep_chunk_size(1)
        self._ensure_min_surfaces(self.MIN_SURFACES)

    def tearDown(self) -> None:
        # MUST reset every knob we touched so we do not break subsequent tests.
        try:
            self.client.debug_set_applicator_slow_ms(0)
        except Exception:
            pass
        try:
            self.client._send_command("debug_force_appearance reset")
        except Exception:
            pass
        try:
            # This also restores chunk size to the production default.
            self.client.debug_reset_appearance_log()
        except Exception:
            pass
        self.client.close()

    def _ensure_min_surfaces(self, min_count: int) -> None:
        """Grow the current workspace to at least ``min_count`` terminal
        surfaces via ``new_split``. Must be enough to observe multi-chunk
        dispatch with chunk size forced to 1.

        Hard-fails (per cmux/CLAUDE.md testing policy) if growth stalls — the
        rest of the suite depends on this count.
        """
        def count() -> int:
            return len(self.client.list_surfaces())

        current = count()
        attempts = 0
        while current < min_count and attempts < min_count * 2:
            try:
                self.client.new_split("right" if attempts % 2 == 0 else "down")
            except cmuxError as e:
                self.fail(
                    f"could not grow to {min_count} surfaces (have {current}): {e}"
                )
            time.sleep(0.15)
            current = count()
            attempts += 1
        if current < min_count:
            self.fail(
                f"could not grow to {min_count} surfaces; plateaued at {current}"
            )

    def _wait_for_sweep_completion(self, expected_scheme: str, timeout_s: float = 3.0) -> dict:
        """Poll until every live surface reports ``expected_scheme`` or timeout."""
        end = time.monotonic() + timeout_s
        last: dict = {"chunks": [], "surfaces": []}
        while time.monotonic() < end:
            self.client.debug_notification_drain()
            last = self.client.debug_dump_appearance_log()
            if last["surfaces"] and all(
                s["scheme"] == expected_scheme for s in last["surfaces"]
            ):
                return last
            time.sleep(0.05)
        return last

    def test_chunked_sweep_records_multiple_chunks(self) -> None:
        """A single appearance flip fans out as >=MIN_SURFACES chunks (one per
        surface, with chunk size forced to 1) and every surface converges on
        the target scheme. A regression to a single synchronous fan-out would
        collapse this to 1 chunk."""
        self.client.debug_set_applicator_slow_ms(20)
        self.assertEqual(
            self.client._send_command("debug_force_appearance dark"), "OK",
        )
        final = self._wait_for_sweep_completion("dark")
        self.assertGreaterEqual(
            len(final["surfaces"]), self.MIN_SURFACES,
            f"setup did not hold {self.MIN_SURFACES} surfaces: {final}",
        )
        for surface in final["surfaces"]:
            self.assertEqual(
                surface["scheme"], "dark",
                f"surface {surface['id']} did not reach dark: {final}",
            )
        # With chunk size 1 and MIN_SURFACES live surfaces, the dark sweep
        # MUST produce at least MIN_SURFACES chunks. A regression to a
        # synchronous fan-out would yield exactly 1 chunk even with many
        # surfaces.
        dark_chunks = [c for c in final["chunks"] if c["scheme"] == "dark"]
        self.assertGreaterEqual(
            len(dark_chunks), self.MIN_SURFACES,
            f"expected >= {self.MIN_SURFACES} dark chunks (chunk size forced "
            f"to 1), got {len(dark_chunks)}: {final}",
        )
        # Every dark chunk must belong to the same generation — a single
        # sweep cannot spawn multiple generations.
        dark_gens = {c["gen"] for c in dark_chunks}
        self.assertEqual(
            len(dark_gens), 1,
            f"single sweep must stay on one generation, got {dark_gens}: {final}",
        )

    def test_rapid_flip_supersedes_older_generation(self) -> None:
        """Firing two appearance flips in quick succession must retire the
        older sweep via generation abort — not double-apply. With chunk size
        1, the first flip enqueues MIN_SURFACES chunks; the second flip bumps
        the generation after the first chunk runs, so at least one older
        chunk MUST be recorded with aborted=1."""
        # 60ms per applicator call so the first sweep cannot drain all of its
        # chunks before we enqueue the second.
        self.client.debug_set_applicator_slow_ms(60)
        self.assertEqual(
            self.client._send_command("debug_force_appearance light"), "OK",
        )
        # Sleep short enough that the first sweep has only drained chunk 0
        # by the time we fire dark.
        time.sleep(0.02)
        self.assertEqual(
            self.client._send_command("debug_force_appearance dark"), "OK",
        )
        final = self._wait_for_sweep_completion("dark", timeout_s=5.0)

        # Final state must be dark (the newer sweep wins) across every
        # surface.
        self.assertGreaterEqual(len(final["surfaces"]), self.MIN_SURFACES, final)
        for surface in final["surfaces"]:
            self.assertEqual(
                surface["scheme"], "dark",
                f"surface {surface['id']} stuck on {surface['scheme']}: {final}",
            )

        # Generation token must advance — two distinct sweeps = two gens.
        gens = sorted({c["gen"] for c in final["chunks"]})
        self.assertGreaterEqual(
            len(gens), 2,
            f"expected >=2 generations in chunk log, got {gens}: {final}",
        )

        # The older generation's later chunks must be marked aborted=1.
        # Without the generation-token abort, every chunk would run to
        # completion, so this assertion is the real regression fence.
        older_gen = gens[0]
        older_chunks = [c for c in final["chunks"] if c["gen"] == older_gen]
        older_aborted = [c for c in older_chunks if c["aborted"]]
        self.assertGreaterEqual(
            len(older_aborted), 1,
            "generation-abort regressed: older gen "
            f"{older_gen} has no aborted chunks. older_chunks={older_chunks} "
            f"final={final}",
        )
        # And every aborted chunk should belong to that older generation
        # (the newer sweep has nothing to abort against).
        for chunk in final["chunks"]:
            if chunk["aborted"]:
                self.assertEqual(
                    chunk["gen"], older_gen,
                    f"newer gen chunk should not be aborted: {chunk} in {final}",
                )

    def test_sweep_log_reset_clears_events(self) -> None:
        """debug_reset_appearance_log drains the ring buffer so tests don't
        bleed state into each other."""
        self.client.debug_set_applicator_slow_ms(0)
        self.client._send_command("debug_force_appearance light")
        self._wait_for_sweep_completion("light")
        self.client.debug_reset_appearance_log()
        after = self.client.debug_dump_appearance_log()
        self.assertEqual(after["chunks"], [])

    def test_appearance_sweep_does_not_fan_out_to_app_update_config(self) -> None:
        """PLAN_thread_leak.md Phase 1 regression: a surface-scoped reload
        MUST NOT be upgraded back into an app-wide
        ``ghostty_app_update_config`` call. That was the O(N^2) renderer
        mailbox amplifier that caused the documented main-thread hang.

        Fires a full appearance cycle (light → dark → reset) and asserts
        the ``app_update_config`` delta is zero while the sweep/reload
        path ran. Surface-level calls are allowed and expected: the test
        simply asserts app-level reloads do not leak into this path.
        """
        self.client.debug_set_applicator_slow_ms(0)
        self.client.debug_reset_reload_counters()
        baseline = self.client.debug_reload_counters()

        self.assertEqual(
            self.client._send_command("debug_force_appearance light"), "OK",
        )
        self._wait_for_sweep_completion("light")
        self.assertEqual(
            self.client._send_command("debug_force_appearance dark"), "OK",
        )
        self._wait_for_sweep_completion("dark")
        self.assertEqual(
            self.client._send_command("debug_force_appearance reset"), "OK",
        )
        self.client.debug_notification_drain()

        final = self.client.debug_reload_counters()
        app_delta = final["app"] - baseline["app"]
        surface_delta = final["surface"] - baseline["surface"]
        self.assertEqual(
            app_delta, 0,
            "surface-target reload path regressed back to app-wide "
            f"ghostty_app_update_config: baseline={baseline} final={final}",
        )
        # If surface_delta is 0 the test is vacuous — either
        # debug_force_appearance no-opped, KVO didn't fire, or the surface
        # reload path was accidentally skipped. Each appearance change
        # emits a surface-target RELOAD_CONFIG per live surface, so with
        # the MIN_SURFACES forced layout a full light→dark→reset cycle
        # MUST drive several surface_update_config calls.
        self.assertGreaterEqual(
            surface_delta, self.MIN_SURFACES,
            "surface reload path did not run — test is vacuous: "
            f"baseline={baseline} final={final} min_surfaces={self.MIN_SURFACES}",
        )

    def test_main_loop_responsive_during_chunked_sweep(self) -> None:
        """Phase 5 main-loop liveness: while a chunked sweep with a slow
        applicator is running, the main run loop must continue to service
        unrelated main-queue work with small inter-reply gaps. A regression
        to a synchronous fan-out (or a long tight prequeue loop) would
        starve that work behind the whole sweep.

        The probe is ``debug_notification_drain`` — its handler does
        ``DispatchQueue.main.sync { /* no-op */ }``, so each reply requires
        the MAIN queue to service an item. ``ping`` would not work here
        because it returns ``PONG`` directly from the socket handler
        thread without ever hopping to main.
        """
        # Pick a slow applicator that guarantees multiple chunks each take
        # meaningful time, but keep total sweep short so the test finishes
        # quickly.
        slow_ms = 40
        self.client.debug_set_applicator_slow_ms(slow_ms)

        gap_samples: list[float] = []
        stop = threading.Event()

        def probe_loop() -> None:
            # Independent client so the probe doesn't share a socket with
            # the sweep's driver.
            probe = cmux()
            probe.connect()
            try:
                prev = time.monotonic()
                while not stop.is_set():
                    # debug_notification_drain forces a main-queue sync on
                    # the server side — the reply is released only after
                    # main has serviced something.
                    probe.debug_notification_drain()
                    now = time.monotonic()
                    gap_samples.append((now - prev) * 1000.0)
                    prev = now
                    # Small pause so we're measuring main-queue interleave,
                    # not CPU burn.
                    time.sleep(0.005)
            except cmuxError:
                pass
            finally:
                probe.close()

        probe_thread = threading.Thread(target=probe_loop, daemon=True)
        probe_thread.start()
        try:
            # Warm-up: let the probe capture a few baseline samples.
            time.sleep(0.1)
            self.assertEqual(
                self.client._send_command("debug_force_appearance dark"), "OK",
            )
            self._wait_for_sweep_completion("dark", timeout_s=5.0)
        finally:
            stop.set()
            probe_thread.join(timeout=2.0)

        # We must have enough samples to be statistically meaningful — if
        # the probe only got one response the sweep starved main entirely.
        self.assertGreater(
            len(gap_samples), 5,
            f"main loop starved probe: only {len(gap_samples)} samples",
        )
        # No single gap should approach the theoretical whole-sweep
        # duration. With chunkSize=1 and MIN_SURFACES=3 and slow_ms=40, a
        # prequeue regression would show a gap >= MIN_SURFACES*slow_ms
        # because the drain's main.sync block would sit behind every
        # queued chunk. The cascade implementation yields gaps close to
        # slow_ms (main services the drain between chunks).
        max_gap = max(gap_samples)
        self.assertLess(
            max_gap,
            slow_ms * self.MIN_SURFACES,
            f"main loop starved: max_gap_ms={max_gap:.0f} samples={gap_samples}",
        )


if __name__ == "__main__":
    unittest.main()
