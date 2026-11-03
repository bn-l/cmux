import AppKit
import Bonsplit
import CmuxControlSocket
import Foundation
import GhosttyKit

extension TerminalController {
    /// Socket error text extracted because `TerminalController.swift` sits at
    /// its file-length budget.
    nonisolated static var terminalSurfaceUnavailableSocketError: String {
        "ERROR: \(terminalSurfaceUnavailableMessage)"
    }
}

/// The surface-domain witnesses are the byte-faithful bodies of the former
/// `v2Surface*` / `v2DebugTerminals` dispatchers, minus the per-read `v2MainSync`
/// hop: the coordinator already runs on the main actor inside the socket-command
/// policy scope, so each hop would re-apply the identical thread-local
/// focus-allowance stack — a no-op.
///
/// App-coupled resolution (`resolveTabManager(routing:)`, `v2ResolveWindowId`, the
/// Bonsplit layout, surface creation/move, the Ghostty reads, the resume approval
/// flow, the `debug.terminals` table) stays here; the seam exposes only Sendable
/// snapshots, resolution enums, and one bridged ``JSONValue`` (`debug.terminals`).
/// Every blocking `NSAlert` and `String(localized:)` resolves here, in the app
/// bundle, so translations survive.
extension TerminalController: ControlSurfaceContext {
    func controlSurfaceRoutingResolvesTabManager(routing: ControlRoutingSelectors) -> Bool {
        resolveTabManager(routing: routing) != nil
    }

    /// The routing twin of the legacy `v2ResolveWorkspace(params:tabManager:)`.
    /// `internal` (not `private`) so the surface witnesses in the sibling
    /// `+ControlSurfaceContext2`/`3` files share it.
    func resolveSurfaceWorkspace(
        routing: ControlRoutingSelectors,
        tabManager: TabManager
    ) -> Workspace? {
        if let wsId = routing.workspaceID {
            return tabManager.tabs.first(where: { $0.id == wsId })
        }
        if let surfaceId = routing.surfaceID {
            if let workspace = tabManager.tabs.first(where: { $0.panels[surfaceId] != nil }) {
                return workspace
            }
            if let workspace = tabManager.tabs.first(where: {
                $0.remoteTmuxControlPane(surfaceID: surfaceId) != nil
            }) {
                return workspace
            }
            return nil
        }
        if let paneId = routing.paneID {
            if let located = v2LocatePane(paneId) {
                guard located.tabManager === tabManager else { return nil }
                return located.workspace
            }
            if let workspace = tabManager.tabs.first(where: {
                $0.remoteTmuxControlPane(paneID: paneId) != nil
            }) {
                return workspace
            }
        }
        guard let wsId = tabManager.selectedTabId else { return nil }
        return tabManager.tabs.first(where: { $0.id == wsId })
    }

    /// Converts an app resume-binding snapshot (after `applyingStoredApproval`) into
    /// the seam value type, byte-faithful to `v2SurfaceResumeBindingPayload`.
    /// `internal` (not `private`) so the resume witnesses in the sibling
    /// `+ControlSurfaceContext3` file share it.
    func controlResumeBinding(
        from binding: SurfaceResumeBindingSnapshot?
    ) -> ControlSurfaceResumeBinding? {
        guard let binding else { return nil }
        let effective = SurfaceResumeApprovalStore.applyingStoredApproval(to: binding)
        return ControlSurfaceResumeBinding(
            name: effective.name,
            kind: effective.kind,
            command: effective.command,
            cwd: effective.cwd,
            checkpointID: effective.checkpointId,
            source: effective.source,
            environment: effective.environment,
            autoResume: effective.allowsAutomaticResume,
            approvalPolicyRawValue: effective.approvalPolicy?.rawValue,
            approvalRecordID: effective.approvalRecordId,
            updatedAt: effective.updatedAt
        )
    }

    // MARK: - list

    func controlSurfaceList(routing: ControlRoutingSelectors) -> ControlSurfaceListSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }

        return ControlSurfaceListSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: controlSurfaceSummaries(workspace: ws)
        )
    }

    // MARK: - current

    func controlSurfaceCurrent(routing: ControlRoutingSelectors) -> ControlSurfaceCurrentSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let containerPanelID = ws.focusedPanelId ?? orderedPanels(in: ws).first?.id
        let projection = containerPanelID.flatMap {
            ws.controlSurfaceProjection(forContainerPanelID: $0)
        }
        return ControlSurfaceCurrentSnapshot(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            paneID: projection?.paneID,
            surfaceID: projection?.surfaceID,
            surfaceTypeRawValue: projection?.panel.panelType.rawValue
        )
    }

    // MARK: - health

    func controlSurfaceHealth(routing: ControlRoutingSelectors) -> ControlSurfaceHealthSnapshot? {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return nil
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else { return nil }
        let items: [ControlSurfaceHealthEntry] = controlSurfacePanels(workspace: ws).map { panel in
            var inWindow: Bool?
            if let tp = panel as? TerminalPanel {
                inWindow = tp.surface.isViewInWindow
            } else if let bp = panel as? BrowserPanel {
                inWindow = bp.webView.window != nil
            }
            return ControlSurfaceHealthEntry(
                surfaceID: panel.id,
                typeRawValue: panel.panelType.rawValue,
                inWindow: inWindow
            )
        }
        return ControlSurfaceHealthSnapshot(
            workspaceID: ws.id,
            windowID: v2ResolveWindowId(tabManager: tabManager),
            surfaces: items
        )
    }

    // MARK: - focus

    func controlSurfaceJumpToLastPrompt() -> ControlSurfaceFocusResolution? {
        guard let app = AppDelegate.shared, let target = app.jumpToLastPrompt() else { return nil }
        return .focused(
            windowID: v2ResolveWindowId(tabManager: app.tabManagerFor(tabId: target.workspaceId)),
            workspaceID: target.workspaceId,
            surfaceID: target.panelId
        )
    }

    func controlSurfaceFocus(
        routing: ControlRoutingSelectors,
        surfaceID: UUID
    ) -> ControlSurfaceFocusResolution {
        guard let tabManager = resolveTabManager(routing: routing) else {
            return .tabManagerUnavailable
        }
        guard let ws = resolveSurfaceWorkspace(routing: routing, tabManager: tabManager) else {
            return .workspaceNotFound
        }
        switch ws.remoteTmuxControlSurfaceTarget(surfaceID: surfaceID) {
        case .pane(let location):
            guard focusRemoteTmuxControlPane(
                location,
                workspace: ws,
                tabManager: tabManager
            ) else {
                return .surfaceNotFound(surfaceID)
            }
            return .focused(
                windowID: v2ResolveWindowId(tabManager: tabManager),
                workspaceID: ws.id,
                surfaceID: location.pane.panel.id
            )
        case .unresolvedMirror:
            return .surfaceNotFound(surfaceID)
        case .notRemote:
            break
        }
        if let windowId = v2ResolveWindowId(tabManager: tabManager) {
            _ = AppDelegate.shared?.focusMainWindow(windowId: windowId)
            setActiveTabManager(tabManager)
        }
        if tabManager.selectedTabId != ws.id {
            tabManager.selectWorkspace(ws)
        }
        guard ws.panels[surfaceID] != nil else {
            return .surfaceNotFound(surfaceID)
        }
        ws.focusPanel(surfaceID)
        return .focused(
            windowID: v2ResolveWindowId(tabManager: tabManager),
            workspaceID: ws.id,
            surfaceID: surfaceID
        )
    }
}
