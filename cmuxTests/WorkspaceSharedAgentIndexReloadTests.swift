import Combine
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Upstream #22748: `SharedLiveAgentIndex` reloads every few seconds while
/// agent hooks write the hook store. Every workspace used to answer each
/// reload with `objectWillChange`, re-running every pane's content and portal
/// reconciliation while the user was idle.
@MainActor
struct WorkspaceSharedAgentIndexReloadTests {
    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func agentIndexReloadDoesNotPublishAnyWorkspace() async throws {
        let manager = TabManager(autoWelcomeIfNeeded: false)
        _ = manager.addWorkspace(select: false)
        _ = manager.addWorkspace(select: false)
        try #require(manager.tabs.count >= 3)
        try #require(manager.tabs.allSatisfy { $0.sharedLiveAgentIndexObserver != nil })
        var publishes = 0
        let sinks = manager.tabs.map { workspace in
            workspace.objectWillChange.sink { _ in publishes += 1 }
        }
        defer { sinks.forEach { $0.cancel() } }

        // New workspaces publish while their terminals and probes start up.
        // Measure only once ten consecutive main-queue turns stay quiet.
        var quietTurns = 0
        for _ in 0..<500 where quietTurns < 10 {
            let before = publishes
            await drainMainQueue()
            quietTurns = publishes == before ? quietTurns + 1 : 0
        }
        try #require(quietTurns >= 10, "The workspaces never went quiet, so the reload cannot be measured")
        publishes = 0

        NotificationCenter.default.post(name: .sharedLiveAgentIndexDidChange, object: SharedLiveAgentIndex.shared)
        // Any Task the observer scheduled runs before these turns complete.
        for _ in 0..<3 { await drainMainQueue() }

        #expect(publishes == 0, "An agent-index reload must not publish any workspace (\(publishes) publishes)")
    }
}
