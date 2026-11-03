import AppKit
import CmuxFoundation
import CmuxTerminal

/// Tracks which main-area panel owns keyboard focus in one main window, so a
/// window regaining key status restores focus to that panel.
@MainActor
final class MainWindowFocusController {
    let windowId: UUID

    private weak var window: NSWindow?
    private weak var tabManager: TabManager?

    private(set) var intent: MainWindowKeyboardFocusIntent? {
        didSet {
            syncBonsplitTabShortcutHintEligibility()
        }
    }

    init(
        windowId: UUID,
        window: NSWindow?,
        tabManager: TabManager
    ) {
        self.windowId = windowId
        self.window = window
        self.tabManager = tabManager
        syncBonsplitTabShortcutHintEligibility()
    }

    func update(
        window: NSWindow?,
        tabManager: TabManager
    ) {
        self.window = window
        self.tabManager = tabManager
        syncBonsplitTabShortcutHintEligibility()
    }

    func noteTerminalInteraction(workspaceId: UUID, panelId: UUID) {
        noteMainPanelInteraction(workspaceId: workspaceId, panelId: panelId)
    }

    func noteMainPanelInteraction(workspaceId: UUID, panelId: UUID) {
        intent = .mainPanel(workspaceId: workspaceId, panelId: panelId)
    }

    func allowsBonsplitTabShortcutHints(workspaceId: UUID) -> Bool {
        guard ShortcutHintDebugSettings().modifierHoldHintsEnabled else { return false }
        guard tabManager?.selectedTabId == workspaceId else { return false }
        switch intent {
        case .mainPanel(let focusedWorkspaceId, _):
            return focusedWorkspaceId == workspaceId
        case nil:
            return true
        }
    }

    @discardableResult
    func restoreTargetAfterWindowBecameKey() -> Bool {
        guard intent != nil,
              let window,
              let tabManager,
              let workspace = tabManager.selectedWorkspace,
              let panelId = workspace.focusedPanelId,
              let panel = workspace.panels[panelId] else {
            return false
        }

        if let responder = window.firstResponder {
            if panel.ownedFocusIntent(for: responder, in: window) != nil {
                noteMainPanelInteraction(workspaceId: workspace.id, panelId: panelId)
                return true
            }
            if terminalFocusRequest(for: responder) == nil,
               selectedFocusedPanelRequest(owning: responder) == nil,
               shouldRespectForeignFirstResponder(responder, in: window) {
                return false
            }
        }

        intent = .mainPanel(workspaceId: workspace.id, panelId: panelId)
        workspace.focusPanel(panelId)
        return panel.restoreFocusIntent(panel.preferredFocusIntentForActivation())
    }

    func syncAfterResponderChange() {
        syncAfterResponderChange(responder: window?.firstResponder)
    }

#if DEBUG
    func debugSyncAfterResponderChange(responder: NSResponder?) {
        syncAfterResponderChange(responder: responder)
    }
#endif

    private func syncAfterResponderChange(responder: NSResponder?) {
        guard let responder else { return }
        if let terminal = terminalFocusRequest(for: responder) {
            noteTerminalInteraction(workspaceId: terminal.workspaceId, panelId: terminal.panelId)
            return
        }
        if let mainPanel = selectedFocusedPanelRequest(owning: responder) {
            noteMainPanelInteraction(workspaceId: mainPanel.workspaceId, panelId: mainPanel.panelId)
        }
    }

    @discardableResult
    func focusTerminal() -> Bool {
        guard let tabManager,
              let workspace = tabManager.selectedWorkspace else {
            return false
        }
        let terminalPanel: TerminalPanel? = {
            if let focusedPanelId = workspace.focusedPanelId,
               let terminalPanel = workspace.terminalPanel(for: focusedPanelId) {
                return terminalPanel
            }
            return workspace.focusedTerminalPanel
        }()
        guard let terminalPanel else { return false }
        intent = .mainPanel(workspaceId: workspace.id, panelId: terminalPanel.id)
        workspace.focusPanel(terminalPanel.id)
        terminalPanel.hostedView.ensureFocus(
            for: workspace.id,
            surfaceId: terminalPanel.id,
            respectForeignFirstResponder: false
        )
        return terminalPanel.hostedView.isSurfaceViewFirstResponder()
    }

    private struct FocusedPanelRequest {
        let workspaceId: UUID
        let panelId: UUID
    }

    private func selectedFocusedPanelRequest(owning responder: NSResponder) -> FocusedPanelRequest? {
        guard let window,
              let tabManager,
              let workspace = tabManager.selectedWorkspace else {
            return nil
        }
        if let panelId = workspace.focusedPanelId,
           let panel = workspace.panels[panelId],
           panel.ownedFocusIntent(for: responder, in: window) != nil {
            return FocusedPanelRequest(workspaceId: workspace.id, panelId: panelId)
        }
        for (panelId, panel) in workspace.panels {
            guard panelId != workspace.focusedPanelId,
                  panel.ownedFocusIntent(for: responder, in: window) != nil else {
                continue
            }
            return FocusedPanelRequest(workspaceId: workspace.id, panelId: panelId)
        }
        return nil
    }

    func syncBonsplitTabShortcutHintEligibility() {
        guard let tabManager else { return }
        for workspace in tabManager.tabs {
            let enabled = allowsBonsplitTabShortcutHints(workspaceId: workspace.id)
            if workspace.bonsplitController.tabShortcutHintsEnabled != enabled {
                workspace.bonsplitController.tabShortcutHintsEnabled = enabled
            }
        }
    }

    private struct TerminalFocusRequest {
        let workspaceId: UUID
        let panelId: UUID
    }

    private func terminalFocusRequest(for responder: NSResponder?) -> TerminalFocusRequest? {
        guard let ghosttyView = cmuxOwningGhosttyView(for: responder),
              let workspaceId = ghosttyView.tabId,
              let panelId = ghosttyView.terminalSurface?.id else {
            return nil
        }
        return TerminalFocusRequest(workspaceId: workspaceId, panelId: panelId)
    }
}
