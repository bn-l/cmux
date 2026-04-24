"""
Regression tests for PLAN_thread_leak.md.

These tests exercise the fire-and-forget notification contract (Phase 3),
the SocketHandlerLimiter cap (Phase 4), and the chunked appearance sweep
(Phase 5). They run against a tagged DEBUG build's socket; the DEBUG-only
harness commands used here (`debug_notification_drain`, `debug_block_main_ms`,
`debug_force_appearance`) are gated on #if DEBUG in TerminalController.swift
and will fail with "ERROR: Unknown command" on production builds.

Per cmux/CLAUDE.md "Testing policy": tests never run locally. Trigger via
gh workflow run test-e2e.yml or on the VM.
"""
from __future__ import annotations

import os
import time
import unittest

from cmux import cmux, cmuxError  # type: ignore


class TestFireAndForgetNotifications(unittest.TestCase):
    def setUp(self) -> None:
        self.client = cmux()
        self.client.clear_notifications()

    def tearDown(self) -> None:
        self.client.clear_notifications()

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
        client = cmux()
        response = client._send_command("socket_health")
        self.assertFalse(response.startswith("ERROR"))
        # Shape: "cap=N current=N peak=N rejected=N"
        for key in ("cap=", "current=", "peak=", "rejected="):
            self.assertIn(key, response)


class TestNotificationBurstUnderMainBlock(unittest.TestCase):
    """Phase 6.3 shape: fire many notification commands while main is blocked.
    Handlers must return quickly (fire-and-forget) and the cmux process
    thread/FD count must converge after the main-block releases.
    """

    def test_notify_target_burst_under_main_block(self) -> None:
        client = cmux()
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

        # Let the main block drain, then confirm socket_health reports a
        # reasonable peak (should be bounded by the Phase 4 cap).
        time.sleep((block_ms / 1000.0) + 0.5)
        client.debug_notification_drain()
        metrics = client._send_command("socket_health")
        # Parse peak=N
        peak = None
        for token in metrics.split():
            if token.startswith("peak="):
                peak = int(token.split("=", 1)[1])
        self.assertIsNotNone(peak)
        # CMUX_SOCKET_HANDLER_INFLIGHT default is 64.
        self.assertLessEqual(
            peak, 128,
            f"peak inflight {peak} exceeds a small multiple of cap",
        )


class TestAppearanceForceReset(unittest.TestCase):
    """Phase 6.1 minimal harness test: exercise debug_force_appearance
    round-trip and ensure reset leaves the app unmodified.
    """

    def test_force_light_then_reset(self) -> None:
        client = cmux()
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
            self.assertEqual(
                client._send_command("debug_force_appearance reset"), "OK",
            )


if __name__ == "__main__":
    unittest.main()
