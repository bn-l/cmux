import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Direct unit tests for `SocketHandlerLimiter` covering the permit owner/drop
/// lifetime hazard called out in PLAN_thread_leak.md Phase 6. The concurrent
/// socket-burst integration test in
/// ``tests/test_thread_leak_regressions.py`` exercises the happy-path defer
/// release across many handler threads; these tests cover the fine-grained
/// owner/drop semantics the plan required:
///
///  - cap=1 strict exclusion
///  - defer release fires on normal scope exit
///  - defer release fires even when the enclosing closure throws
///  - concurrent acquirers never exceed the cap under race pressure
///  - rejected counter increments on each refused tryAcquire
///  - peak tracks the max observed inflight count
final class SocketHandlerLimiterTests: XCTestCase {
    func testCapOneEnforcesStrictExclusion() {
        let limiter = SocketHandlerLimiter(cap: 1)

        XCTAssertTrue(limiter.tryAcquire(), "first acquire should succeed")
        XCTAssertFalse(limiter.tryAcquire(), "second acquire must fail while permit held")

        var m = limiter.metricsSnapshot()
        XCTAssertEqual(m.cap, 1)
        XCTAssertEqual(m.currentInflight, 1)
        XCTAssertEqual(m.peakInflight, 1)
        XCTAssertEqual(m.rejectedCount, 1)

        limiter.release()

        XCTAssertTrue(limiter.tryAcquire(), "acquire must succeed once the prior permit is released")
        m = limiter.metricsSnapshot()
        XCTAssertEqual(m.currentInflight, 1)
        XCTAssertEqual(m.peakInflight, 1)

        limiter.release()

        let final = limiter.metricsSnapshot()
        XCTAssertEqual(final.currentInflight, 0, "currentInflight must return to 0 after matched release")
        // Peak is a high-water mark — it does NOT decrement.
        XCTAssertEqual(final.peakInflight, 1)
        XCTAssertEqual(final.rejectedCount, 1)
    }

    /// Simulates the production handleClient pattern:
    ///     Thread.detachNewThread {
    ///         defer { limiter.release() }   // captures limiter strongly
    ///         ...work...
    ///     }
    /// The deferred release MUST fire even if the enclosing scope exits
    /// via a thrown error rather than a normal return. Without this, a
    /// failure path inside handleClient would silently shrink the cap.
    func testDeferReleasesPermitWhenClosureThrows() {
        let limiter = SocketHandlerLimiter(cap: 2)

        struct HandlerFailure: Error {}

        XCTAssertTrue(limiter.tryAcquire())
        XCTAssertTrue(limiter.tryAcquire())
        XCTAssertEqual(limiter.metricsSnapshot().currentInflight, 2)

        // Scope 1 — normal return with defer.
        func releaseOnReturn() {
            defer { limiter.release() }
        }
        releaseOnReturn()
        XCTAssertEqual(limiter.metricsSnapshot().currentInflight, 1,
                       "defer release on normal exit must return the permit")

        // Scope 2 — thrown error with defer. Contract: defer STILL fires.
        func releaseThenThrow() throws {
            defer { limiter.release() }
            throw HandlerFailure()
        }
        do {
            try releaseThenThrow()
            XCTFail("HandlerFailure must propagate")
        } catch is HandlerFailure {
            // expected
        } catch {
            XCTFail("unexpected error: \(error)")
        }

        XCTAssertEqual(limiter.metricsSnapshot().currentInflight, 0,
                       "defer release must fire even when the enclosing closure throws")
    }

    /// Spawn many threads each trying to acquire+release under a cap below the
    /// thread count. The invariant: at no observed moment does
    /// currentInflight exceed cap, and peakInflight ends equal to cap.
    func testConcurrentAcquireNeverExceedsCap() {
        let cap = 4
        let limiter = SocketHandlerLimiter(cap: cap)
        let attempts = 256

        let group = DispatchGroup()
        let queue = DispatchQueue.global(qos: .userInitiated)
        let held = DispatchSemaphore(value: 0)
        // Block accepted workers for a moment so concurrent contention is real.
        let holdWindow = DispatchSemaphore(value: 0)

        var acceptedCount = 0
        let acceptedLock = NSLock()

        for _ in 0..<attempts {
            group.enter()
            queue.async {
                defer { group.leave() }
                guard limiter.tryAcquire() else { return }
                acceptedLock.lock()
                acceptedCount += 1
                acceptedLock.unlock()
                held.signal()
                _ = holdWindow.wait(timeout: .now() + .seconds(2))
                limiter.release()
            }
        }

        // Wait until `cap` workers report accepted.
        for _ in 0..<cap {
            _ = held.wait(timeout: .now() + .seconds(2))
        }

        let midSnapshot = limiter.metricsSnapshot()
        XCTAssertLessThanOrEqual(midSnapshot.currentInflight, cap,
                                 "currentInflight exceeded cap under concurrent contention")
        XCTAssertEqual(midSnapshot.peakInflight, cap,
                       "peakInflight must reach cap under concurrent contention")

        // Release all holders.
        for _ in 0..<cap {
            holdWindow.signal()
        }
        group.wait()

        let final = limiter.metricsSnapshot()
        XCTAssertEqual(final.currentInflight, 0,
                       "permits leaked after matched release: \(final)")
        XCTAssertEqual(final.peakInflight, cap)
        XCTAssertGreaterThan(final.rejectedCount, 0,
                             "rejected should increment when >cap acquirers contend")
        acceptedLock.lock()
        XCTAssertLessThanOrEqual(acceptedCount, attempts)
        acceptedLock.unlock()
    }

    /// Every refused tryAcquire MUST bump rejectedCount exactly once and MUST
    /// NOT increment currentInflight.
    func testRejectedCountIncrementsPerRefusal() {
        let limiter = SocketHandlerLimiter(cap: 1)
        XCTAssertTrue(limiter.tryAcquire())

        let refuseAttempts = 7
        for _ in 0..<refuseAttempts {
            XCTAssertFalse(limiter.tryAcquire())
        }

        let m = limiter.metricsSnapshot()
        XCTAssertEqual(m.rejectedCount, UInt64(refuseAttempts))
        XCTAssertEqual(m.currentInflight, 1,
                       "refused tryAcquire must not mutate currentInflight")

        limiter.release()
        XCTAssertEqual(limiter.metricsSnapshot().currentInflight, 0)
    }

    /// Spelled out as a separate test because the contract "defer release
    /// captures limiter strongly so the permit is always released, even if
    /// self is deallocated before the block runs" is explicitly called out
    /// in TerminalController.swift — the limiter outlives the controller.
    func testLimiterOutlivesCapturingClosure() {
        let limiter = SocketHandlerLimiter(cap: 1)
        XCTAssertTrue(limiter.tryAcquire())

        // Capture strongly, then drop every outer reference and run the
        // deferred release. The limiter must stay alive through the release.
        do {
            let captured = limiter
            let exitExpectation = expectation(description: "deferred release runs")
            Thread.detachNewThread {
                defer {
                    captured.release()
                    exitExpectation.fulfill()
                }
                // Simulate a handler that briefly does nothing and returns
                // normally — defer MUST still run.
            }
            wait(for: [exitExpectation], timeout: 2.0)
        }

        XCTAssertEqual(limiter.metricsSnapshot().currentInflight, 0,
                       "deferred release captured via closure must fire even after outer scope exits")
    }
}
