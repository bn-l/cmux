import Foundation
import Testing
@testable import CmuxControlSocket

@MainActor
@Suite("ControlCommandCoordinator surface domain")
struct ControlCommandCoordinatorSurfaceTests {
    /// The right-sidebar Dock is gone: a `dock` placement (or any value other
    /// than `workspace`) fails loudly before the app creates anything, instead
    /// of silently landing in the workspace.
    @Test(arguments: ["surface.create", "pane.create"], ["dock", "sidebar", "Workspace"])
    func createRejectsEveryPlacementButWorkspaceBeforeCallingTheApp(method: String, placement: String) {
        // Arrange
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)

        // Act
        let result = coordinator.handle(ControlRequest(
            id: .int(1),
            method: method,
            params: ["direction": .string("right"), "type": .string("terminal"), "placement": .string(placement)]
        ))

        // Assert
        #expect(result == .err(
            code: "invalid_params",
            message: "placement must be: workspace",
            data: .object(["placement": .string(placement)])
        ))
        #expect(context.paneCreateCallCount == 0)
        #expect(context.surfaceCreateCallCount == 0)
    }

    @Test(arguments: [nil, "workspace"] as [String?])
    func createWithWorkspaceOrNoPlacementReachesTheApp(placement: String?) {
        // Arrange
        let context = FakeSurfaceControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        var params: [String: JSONValue] = ["direction": .string("right"), "type": .string("terminal")]
        if let placement { params["placement"] = .string(placement) }

        // Act
        _ = coordinator.handle(ControlRequest(id: .int(1), method: "pane.create", params: params))
        _ = coordinator.handle(ControlRequest(id: .int(2), method: "surface.create", params: params))

        // Assert
        #expect(context.paneCreateCallCount == 1)
        #expect(context.surfaceCreateCallCount == 1)
    }

    private func makeCoordinator() -> (ControlCommandCoordinator, FakeSurfaceControlCommandContext) {
        let context = FakeSurfaceControlCommandContext()
        return (ControlCommandCoordinator(context: context), context)
    }

    private func request(_ params: [String: JSONValue]) -> ControlRequest {
        ControlRequest(id: .int(1), method: "surface.report_pwd", params: params)
    }

    @Test func reportPWDRejectsConflictingPathAliases() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        let result = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "path": .string("/srv/work/bar"),
            "cwd": .string("/srv/work/other"),
        ]))

        #expect(result == .err(code: "invalid_params", message: "Conflicting path parameters", data: nil))
        #expect(context.reportedPWD?.path == nil)
    }

    @Test func reportPWDPreservesExactPathWhitespace() {
        let (coordinator, context) = makeCoordinator()
        let workspaceID = UUID()
        _ = coordinator.handle(request([
            "workspace_id": .string(workspaceID.uuidString),
            "path": .string("/srv/work/bar "),
        ]))

        #expect(context.reportedPWD?.path == "/srv/work/bar ")
    }
}
