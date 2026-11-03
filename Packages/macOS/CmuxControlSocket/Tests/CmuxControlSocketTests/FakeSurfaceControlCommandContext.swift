import Foundation
@testable import CmuxControlSocket

@MainActor
final class FakeSurfaceControlCommandContext: ControlCommandContext {
    var paneCreateResolution: ControlPaneCreateResolution = .tabManagerUnavailable
    var createResolution: ControlSurfaceCreateResolution = .tabManagerUnavailable
    var reportPWDResolution: ControlSurfaceReportPWDResolution = .recorded(surfaceID: UUID())
    var reportedPWD: (workspaceID: UUID, requestedSurfaceID: UUID?, path: String)?
    var focusResolution: ControlSurfaceFocusResolution = .tabManagerUnavailable
    var jumpToLastPromptResolution: ControlSurfaceFocusResolution?
    private(set) var paneCreateCallCount = 0
    private(set) var surfaceCreateCallCount = 0

    func controlWindowSummaries() -> [ControlWindowSummary] { [] }
    func controlResolveCurrentWindow(routing: ControlRoutingSelectors) -> ControlCurrentWindowResolution {
        .tabManagerUnavailable
    }
    func controlFocusWindow(id: UUID) -> Bool { false }
    func controlCreateWindowAndActivate() -> UUID? { nil }
    func controlCloseWindow(id: UUID) -> Bool { false }
    func controlAvailableDisplays() -> [ControlDisplayInfo] { [] }
    func controlWindowExists(id: UUID) -> Bool { false }
    func controlMoveWindow(id: UUID, toDisplayMatching query: String) -> String? { nil }
    func controlMoveAllWindows(toDisplayMatching query: String) -> ControlMoveAllWindowsResult? { nil }
    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool { true }
    func controlPaneRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool { true }

    func controlPaneCreate(
        routing: ControlRoutingSelectors,
        inputs: ControlPaneCreateInputs
    ) -> ControlPaneCreateResolution {
        paneCreateCallCount += 1
        return paneCreateResolution
    }

    func controlSurfaceCreate(
        routing: ControlRoutingSelectors,
        inputs: ControlSurfaceCreateInputs
    ) -> ControlSurfaceCreateResolution {
        surfaceCreateCallCount += 1
        return createResolution
    }

    func controlSurfaceReportPWD(
        workspaceID: UUID,
        requestedSurfaceID: UUID?,
        path: String
    ) -> ControlSurfaceReportPWDResolution {
        reportedPWD = (workspaceID, requestedSurfaceID, path)
        return reportPWDResolution
    }

    func controlSurfaceFocus(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlSurfaceFocusResolution {
        focusResolution
    }

    func controlSurfaceJumpToLastPrompt() -> ControlSurfaceFocusResolution? {
        jumpToLastPromptResolution
    }
}
