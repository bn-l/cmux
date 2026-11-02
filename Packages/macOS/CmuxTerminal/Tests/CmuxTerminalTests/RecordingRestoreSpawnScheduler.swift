import Foundation
@testable import CmuxTerminal

@MainActor
final class RecordingRestoreSpawnScheduler: TerminalSurfaceRuntimeSpawnScheduling {
    private(set) var scheduledSurfaceIds: [UUID] = []
    private(set) var scheduledResumesAgent: [Bool] = []
    private var scheduledOperations: [@MainActor () -> Void] = []

    func scheduleRestoredSurfaceSpawn(
        surfaceId: UUID,
        resumesAgent: Bool,
        operation: @escaping @MainActor () -> Void
    ) {
        scheduledSurfaceIds.append(surfaceId)
        scheduledResumesAgent.append(resumesAgent)
        scheduledOperations.append(operation)
    }

    func runScheduledOperation(at index: Int = 0) {
        scheduledOperations[index]()
    }
}
