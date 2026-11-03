import AppKit
import Combine
import CmuxWorkspaces
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspaceRecoveryReviewRegressionTests {
    @Test
    func loadTimeWorkspaceCapacityTrimIsPersisted() async throws {
        let temporaryDirectory = FileManager.default.temporaryDirectory
            .appending(path: "cmux-closed-workspace-trim-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
        let historyURL = temporaryDirectory.appending(path: "history.json")
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let workspace = try #require(manager.selectedWorkspace)

        let seedStore = ClosedItemHistoryStore(
            workspaceCapacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        for index in 0..<3 {
            seedStore.push(workspaceRecord(index: index, from: workspace))
        }

        let boundedStore = ClosedItemHistoryStore(
            workspaceCapacity: 2,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: false,
            persistsRecordsSynchronously: true
        )
        let loadedRevision = await boundedStore.$revision.values.first { $0 > 0 }
        #expect(loadedRevision != nil)
        #expect(boundedStore.menuSnapshot().totalItemCount == 2)

        let reloadedStore = ClosedItemHistoryStore(
            workspaceCapacity: nil,
            fileURL: historyURL,
            loadsPersistedRecordsSynchronously: true,
            persistsRecordsSynchronously: true
        )
        #expect(reloadedStore.menuSnapshot().totalItemCount == 2)
        #expect(reloadedStore.menuSnapshot().items.map(\.title) == ["Closed 2", "Closed 1"])
    }

    private func workspaceRecord(
        index: Int,
        from workspace: Workspace
    ) -> ClosedItemHistoryRecord {
        var snapshot = workspace.sessionSnapshot(includeScrollback: false)
        snapshot.customTitle = "Closed \(index)"
        return ClosedItemHistoryRecord(
            closedAt: Date(timeIntervalSince1970: TimeInterval(index)),
            entry: .workspace(ClosedWorkspaceHistoryEntry(
                workspaceId: UUID(),
                windowId: nil,
                workspaceIndex: index,
                snapshot: snapshot
            ))
        )
    }
}
