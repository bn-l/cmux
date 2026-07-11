import Foundation

/// Bounded dispatch limiter for socket accept-handler threads.
/// Guards the per-connection `Thread.detachNewThread` spawn in
/// `TerminalController.spawnClientHandler` so a stalled main thread cannot
/// produce thread/FD runaway: command bodies may block on main-thread sync
/// hops, so under a stalled main a burst of N connections would otherwise pin
/// N threads with no bound. With the limiter, excess connections are refused
/// with `ERROR: server_busy` and the kernel listen backlog absorbs the rest.
///
/// Marked `@unchecked Sendable` because the instance is used from a
/// nonisolated accept-consumer task and from worker blocks; internal state is
/// either immutable (`cap`, `inflight`) or guarded by `metricsLock`.
final class SocketHandlerLimiter: @unchecked Sendable {
    let cap: Int
    private let inflight: DispatchSemaphore

    private let metricsLock = NSLock()
    private var _currentInflight: Int = 0
    private var _peakInflight: Int = 0
    private var _rejectedCount: UInt64 = 0

    struct Metrics {
        let cap: Int
        let currentInflight: Int
        let peakInflight: Int
        let rejectedCount: UInt64
    }

    init(cap: Int) {
        self.cap = cap
        self.inflight = DispatchSemaphore(value: cap)
    }

    /// Non-blocking permit acquire. Returns false if all permits are in use
    /// (and increments the rejected counter as a side effect).
    func tryAcquire() -> Bool {
        guard inflight.wait(timeout: .now()) != .timedOut else {
            metricsLock.lock()
            _rejectedCount &+= 1
            metricsLock.unlock()
            return false
        }
        metricsLock.lock()
        _currentInflight += 1
        if _currentInflight > _peakInflight { _peakInflight = _currentInflight }
        metricsLock.unlock()
        return true
    }

    /// Return a permit previously granted by `tryAcquire()`. Must be called
    /// exactly once per successful acquire; leaking a permit silently shrinks
    /// the cap. Caller pattern:
    /// ```swift
    /// guard limiter.tryAcquire() else { reject(); return }
    /// Thread.detachNewThread {
    ///     defer { limiter.release() }   // captures limiter strongly
    ///     // ...
    /// }
    /// ```
    func release() {
        metricsLock.lock()
        _currentInflight -= 1
        metricsLock.unlock()
        inflight.signal()
    }

    /// Snapshot metrics for diagnostics. Safe from any thread.
    func metricsSnapshot() -> Metrics {
        metricsLock.lock()
        defer { metricsLock.unlock() }
        return Metrics(
            cap: cap,
            currentInflight: _currentInflight,
            peakInflight: _peakInflight,
            rejectedCount: _rejectedCount
        )
    }
}
