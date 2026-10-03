import Foundation

// Ported with upstream #9179 (DeferredActionReplacementStackTests needs it); upstream
// defines it in SidebarSelectionCoalescerTests.swift, which this fork does not have.
/// Deterministic clock: sleeps suspend until the test advances time. Every
/// mutable field is protected by `lock`; `Clock` requires synchronous `now`
/// and sleep registration, so actor isolation cannot provide the same API.
final class SidebarTestManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol, Sendable {
        var offset: Duration

        func advanced(by duration: Duration) -> Instant {
            Instant(offset: offset + duration)
        }

        func duration(to other: Instant) -> Duration {
            other.offset - offset
        }

        static func < (lhs: Instant, rhs: Instant) -> Bool {
            lhs.offset < rhs.offset
        }
    }

    private struct Sleeper {
        let deadline: Instant
        let continuation: CheckedContinuation<Void, any Error>
    }

    private struct SleepWaiter {
        let deadline: Instant?
        let continuation: CheckedContinuation<Void, Never>
    }

    private let lock = NSLock()
    private var _now = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]
    private var pendingSleeperRegistrationIDs: Set<UUID> = []
    private var cancelledSleeperIDs: Set<UUID> = []
    private var sleepWaiters: [SleepWaiter] = []
    private var sleepWaiterRegistrationCount = 0
    private var sleepWaiterRegistrationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private var idleWaiters: [CheckedContinuation<Void, Never>] = []
    private var idleWaiterRegistrationCount = 0
    private var idleWaiterRegistrationWaiters: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []
    private let beforeRegisteringSleeper: @Sendable () async -> Void

    init(beforeRegisteringSleeper: @escaping @Sendable () async -> Void = {}) {
        self.beforeRegisteringSleeper = beforeRegisteringSleeper
    }

    private var isIdleLocked: Bool {
        sleepers.isEmpty && pendingSleeperRegistrationIDs.isEmpty
    }

    private func takeIdleWaitersIfIdleLocked() -> [CheckedContinuation<Void, Never>] {
        guard isIdleLocked else { return [] }
        let waiters = idleWaiters
        idleWaiters.removeAll()
        return waiters
    }

    private func takeSleepWaitersLocked(
        matching deadline: Instant
    ) -> [CheckedContinuation<Void, Never>] {
        var matchedWaiters: [CheckedContinuation<Void, Never>] = []
        sleepWaiters.removeAll { waiter in
            let matches = waiter.deadline == nil || waiter.deadline == deadline
            if matches { matchedWaiters.append(waiter.continuation) }
            return matches
        }
        return matchedWaiters
    }

    var now: Instant {
        lock.lock()
        defer { lock.unlock() }
        return _now
    }

    var minimumResolution: Duration { .zero }

    var retainedCancellationMarkerCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return cancelledSleeperIDs.count
    }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        lock.lock()
        pendingSleeperRegistrationIDs.insert(id)
        lock.unlock()
        try await withTaskCancellationHandler {
            await beforeRegisteringSleeper()
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                lock.lock()
                pendingSleeperRegistrationIDs.remove(id)
                if cancelledSleeperIDs.remove(id) != nil {
                    let waiters = takeIdleWaitersIfIdleLocked()
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                    for waiter in waiters { waiter.resume() }
                    return
                }
                if deadline <= _now {
                    let sleepWaiters = takeSleepWaitersLocked(matching: deadline)
                    let idleWaiters = takeIdleWaitersIfIdleLocked()
                    lock.unlock()
                    continuation.resume()
                    for waiter in sleepWaiters { waiter.resume() }
                    for waiter in idleWaiters { waiter.resume() }
                    return
                }
                sleepers[id] = Sleeper(deadline: deadline, continuation: continuation)
                let matchedWaiters = takeSleepWaitersLocked(matching: deadline)
                lock.unlock()
                for waiter in matchedWaiters { waiter.resume() }
            }
        } onCancel: {
            lock.lock()
            let sleeper = sleepers.removeValue(forKey: id)
            if sleeper == nil, pendingSleeperRegistrationIDs.contains(id) {
                cancelledSleeperIDs.insert(id)
            }
            let waiters = takeIdleWaitersIfIdleLocked()
            lock.unlock()
            sleeper?.continuation.resume(throwing: CancellationError())
            for waiter in waiters { waiter.resume() }
        }
    }

    func waitUntilSleeping(for duration: Duration? = nil) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            let deadline = duration.map { _now.advanced(by: $0) }
            let alreadySleeping = sleepers.values.contains { sleeper in
                deadline == nil || sleeper.deadline == deadline
            }
            if alreadySleeping {
                lock.unlock()
                continuation.resume()
            } else {
                sleepWaiters.append(SleepWaiter(deadline: deadline, continuation: continuation))
                sleepWaiterRegistrationCount += 1
                var registrationWaiters: [CheckedContinuation<Void, Never>] = []
                sleepWaiterRegistrationWaiters.removeAll { waiter in
                    if sleepWaiterRegistrationCount >= waiter.count {
                        registrationWaiters.append(waiter.continuation)
                        return true
                    }
                    return false
                }
                lock.unlock()
                for waiter in registrationWaiters { waiter.resume() }
            }
        }
    }

    func waitUntilSleepWaiterRegistered(_ count: Int = 1) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if sleepWaiterRegistrationCount >= count {
                lock.unlock()
                continuation.resume()
            } else {
                sleepWaiterRegistrationWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }

    var pendingSleepWaiterCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return sleepWaiters.count
    }

    func releasePendingSleepWaitersForTesting() {
        lock.lock()
        let waiters = sleepWaiters.map(\.continuation)
        sleepWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume() }
    }

    func advance(by duration: Duration, beforeResuming: () -> Void = {}) {
        lock.lock()
        _now = _now.advanced(by: duration)
        let dueIDs = sleepers.compactMap { id, sleeper in
            sleeper.deadline <= _now ? id : nil
        }
        let due = dueIDs.compactMap { sleepers.removeValue(forKey: $0) }
        let waiters = takeIdleWaitersIfIdleLocked()
        lock.unlock()
        beforeResuming()
        for sleeper in due {
            sleeper.continuation.resume()
        }
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilIdle() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if isIdleLocked {
                lock.unlock()
                continuation.resume()
            } else {
                idleWaiters.append(continuation)
                idleWaiterRegistrationCount += 1
                var registrationWaiters: [CheckedContinuation<Void, Never>] = []
                idleWaiterRegistrationWaiters.removeAll { waiter in
                    if idleWaiterRegistrationCount >= waiter.count {
                        registrationWaiters.append(waiter.continuation)
                        return true
                    }
                    return false
                }
                lock.unlock()
                for waiter in registrationWaiters { waiter.resume() }
            }
        }
    }

    func waitUntilIdleWaiterRegistered(_ count: Int = 1) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            if idleWaiterRegistrationCount >= count {
                lock.unlock()
                continuation.resume()
            } else {
                idleWaiterRegistrationWaiters.append((count, continuation))
                lock.unlock()
            }
        }
    }
}
