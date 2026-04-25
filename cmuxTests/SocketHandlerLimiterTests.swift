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

    /// Models the exact Phase 6.4 owner-drop hazard from
    /// TerminalController.swift:1551-1566:
    ///
    ///     let limiter = handlerLimiter        // strong LOCAL capture
    ///     Thread.detachNewThread { [weak self] in
    ///         defer { limiter.release() }     // captures the strong local
    ///         guard let self else { close(clientSocket); return }
    ///         ...
    ///     }
    ///
    /// The hazard: if the controller (`self`) is deallocated before the
    /// queued handler runs, the permit must STILL be released — otherwise
    /// every controller turnover during a socket burst leaks cap permits
    /// and eventually the limiter runs dry. The production code copies the
    /// limiter out to a local so the closure strongly retains the limiter
    /// independently of `self`. This test simulates that: an `Owner`
    /// (stand-in for the controller) goes away BEFORE the closure runs,
    /// and the permit still returns.
    func testReleaseFiresEvenWhenOwnerDeallocatesBeforeClosureRuns() {
        final class Owner {
            let limiter: SocketHandlerLimiter
            init(_ limiter: SocketHandlerLimiter) { self.limiter = limiter }
        }

        let externalLimiter = SocketHandlerLimiter(cap: 1)
        XCTAssertTrue(externalLimiter.tryAcquire())

        let gate = DispatchSemaphore(value: 0)
        let done = expectation(description: "deferred release runs after owner dies")
        weak var weakOwner: Owner?

        do {
            let owner = Owner(externalLimiter)
            weakOwner = owner
            // Production pattern: copy out a strong reference to the
            // limiter so the closure does NOT need `owner`/`self` alive.
            let strongLimiter = owner.limiter
            Thread.detachNewThread { [weak owner] in
                defer {
                    strongLimiter.release()
                    done.fulfill()
                }
                // Block until the outer scope has dropped its strong ref
                // to `owner`, so by the time we release, the "controller"
                // is already gone.
                gate.wait()
                _ = owner  // silence unused-capture warning; weak owner is nil by here
            }
            // `owner` goes out of scope at the end of this `do` block —
            // the only strong reference is gone, so the object deallocates.
        }
        XCTAssertNil(weakOwner,
                     "Owner must have deallocated before the closure releases — "
                     + "otherwise this test is not exercising the owner-drop hazard")

        gate.signal()
        wait(for: [done], timeout: 2.0)

        XCTAssertEqual(externalLimiter.metricsSnapshot().currentInflight, 0,
                       "strong local limiter capture must release the permit even "
                       + "when the owner is dead by the time the handler runs")
    }

    /// Negative control — documents exactly why the production code copies
    /// the limiter out to a local before `Thread.detachNewThread`. If a
    /// refactor regressed to `defer { self?.handlerLimiter.release() }`
    /// (or equivalent `[weak owner]` form), this is what would happen: the
    /// owner dies first, `owner?` resolves to nil, release never fires,
    /// the permit leaks forever. A failure of THIS test means Swift's
    /// weak-capture/optional-chaining semantics changed under us, which
    /// would invalidate other strong-capture assumptions in the codebase.
    func testWeakOwnerReleaseLeaksPermitWhenOwnerDiesFirst() {
        final class Owner {
            let limiter: SocketHandlerLimiter
            init(_ limiter: SocketHandlerLimiter) { self.limiter = limiter }
        }

        let externalLimiter = SocketHandlerLimiter(cap: 1)
        XCTAssertTrue(externalLimiter.tryAcquire())

        let gate = DispatchSemaphore(value: 0)
        let done = expectation(description: "handler ran (leak path)")
        weak var weakOwner: Owner?

        do {
            let owner = Owner(externalLimiter)
            weakOwner = owner
            Thread.detachNewThread { [weak owner] in
                defer {
                    // REGRESSION pattern — owner is nil by the time the
                    // deferred block runs, so release() is NEVER called.
                    owner?.limiter.release()
                    done.fulfill()
                }
                gate.wait()
            }
        }
        XCTAssertNil(weakOwner, "owner must have deallocated before the handler runs")

        gate.signal()
        wait(for: [done], timeout: 2.0)

        XCTAssertEqual(externalLimiter.metricsSnapshot().currentInflight, 1,
                       "regression simulation: `owner?.limiter.release()` silently "
                       + "leaks the permit when the owner dies before the handler "
                       + "runs. The production code strongly captures the limiter "
                       + "via a local precisely to avoid this.")
    }
}
