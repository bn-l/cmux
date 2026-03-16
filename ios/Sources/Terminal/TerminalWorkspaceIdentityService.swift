import Foundation

enum TerminalWorkspaceIdentityError: Error, Sendable {
    case missingTeamID
}

@MainActor
protocol TerminalWorkspaceIdentityReserving {
    func reserveWorkspace(for host: TerminalHost) async throws -> TerminalWorkspaceBackendIdentity
}

@MainActor
struct TerminalConvexWorkspaceIdentityService: TerminalWorkspaceIdentityReserving {
    func reserveWorkspace(for host: TerminalHost) async throws -> TerminalWorkspaceBackendIdentity {
        guard let teamID = host.teamID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !teamID.isEmpty else {
            throw TerminalWorkspaceIdentityError.missingTeamID
        }

        let args = LocalWorkspacesReserveArgs(
            linkedFromCloudTaskRunId: nil,
            projectFullName: nil,
            repoUrl: nil,
            branch: nil,
            teamSlugOrId: teamID
        )
        let response: LocalWorkspacesReserveReturn = try await ConvexClientManager.shared.client.mutation(
            "localWorkspaces:reserve",
            with: args.asDictionary()
        )

        return TerminalWorkspaceBackendIdentity(
            teamID: teamID,
            taskID: response.taskId.rawValue,
            taskRunID: response.taskRunId.rawValue,
            workspaceName: response.workspaceName,
            descriptor: response.descriptor
        )
    }
}
