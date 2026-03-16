import Combine
import ConvexMobile
import Foundation

@MainActor
protocol TerminalWorkspaceMetadataStreaming {
    func metadataPublisher(for identity: TerminalWorkspaceBackendIdentity) -> AnyPublisher<TerminalWorkspaceBackendMetadata, Never>
}

@MainActor
struct TerminalConvexWorkspaceMetadataService: TerminalWorkspaceMetadataStreaming {
    func metadataPublisher(for identity: TerminalWorkspaceBackendIdentity) -> AnyPublisher<TerminalWorkspaceBackendMetadata, Never> {
        let args = TasksGetLinkedLocalWorkspaceArgs(
            teamSlugOrId: identity.teamID,
            cloudTaskRunId: ConvexId(rawValue: identity.taskRunID)
        )

        return ConvexClientManager.shared.client
            .subscribe(
                to: "tasks:getLinkedLocalWorkspace",
                with: args.asDictionary(),
                yielding: TasksGetLinkedLocalWorkspaceReturn.self
            )
            .map(TerminalWorkspaceBackendMetadata.init(linkedWorkspace:))
            .catch { _ in
                Empty<TerminalWorkspaceBackendMetadata, Never>()
            }
            .eraseToAnyPublisher()
    }
}

private extension TerminalWorkspaceBackendMetadata {
    init(linkedWorkspace: TasksGetLinkedLocalWorkspaceReturn) {
        self.init(
            preview: Self.normalized(linkedWorkspace.taskRun.summary) ??
                Self.normalized(linkedWorkspace.taskRun.newBranch) ??
                Self.normalized(linkedWorkspace.task.projectFullName) ??
                Self.normalized(linkedWorkspace.task.text)
        )
    }

    static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
