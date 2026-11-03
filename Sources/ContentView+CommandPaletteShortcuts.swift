import CmuxPanes
import AppKit

extension ContentView {
    static func commandPaletteShortcutAction(forCommandID commandId: String) -> KeyboardShortcutSettings.Action? {
        switch commandId {
        case "palette.newWorkspace":
            return .newTab
        case "palette.newBrowserWorkspace":
            return .newBrowserWorkspace
        case "palette.newWindow":
            return .newWindow
        case "palette.openFolder":
            return .openFolder
        case "palette.reopenPreviousSession":
            return .reopenPreviousSession
        case "palette.reopenClosedBrowserTab":
            return .reopenClosedBrowserPanel
        case "palette.newTerminalTab":
            return .newSurface
        case "palette.newBrowserTab":
            return .openBrowser
        case "palette.closeWindow":
            return .closeWindow
        case "palette.toggleSidebar":
            return .toggleSidebar
        case "palette.showNotifications":
            return .showNotifications
        case "palette.jumpUnread":
            return .jumpToUnread
        case "palette.toggleUnread":
            return .toggleUnread
        case "palette.markOldestUnreadAndJumpNext":
            return .markOldestUnreadAndJumpNext
        case "palette.renameTab":
            return .renameTab
        case "palette.renameWorkspace":
            return .renameWorkspace
        case "palette.editWorkspaceDescription":
            return .editWorkspaceDescription
        case "palette.nextWorkspace":
            return .nextSidebarTab
        case "palette.previousWorkspace":
            return .prevSidebarTab
        case "palette.nextTabInPane":
            return .nextSurface
        case "palette.previousTabInPane":
            return .prevSurface
        case "palette.browserToggleDevTools":
            return .toggleBrowserDeveloperTools
        case "palette.browserConsole":
            return .showBrowserJavaScriptConsole
        case "palette.browserReactGrab":
            return .toggleReactGrab
        case "palette.browserSplitRight", "palette.terminalSplitBrowserRight":
            return .splitBrowserRight
        case "palette.browserSplitDown", "palette.terminalSplitBrowserDown":
            return .splitBrowserDown
        case "palette.terminalSplitRight":
            return .splitRight
        case "palette.terminalSplitDown":
            return .splitDown
        case "palette.terminalFind":
            return .find
        case "palette.terminalFindNext":
            return .findNext
        case "palette.terminalFindPrevious":
            return .findPrevious
        case "palette.terminalHideFind":
            return .hideFind
        case "palette.terminalUseSelectionForFind":
            return .useSelectionForFind
        case "palette.terminalFocusTextBoxInput":
            return .focusTextBoxInput
        case "palette.terminalAttachTextBoxFile":
            return .attachTextBoxFile
        case "palette.terminalSendCtrlF":
            return .sendCtrlFToTerminal
        case "palette.terminalClearScreenKeepScrollback":
            return .clearScreenKeepScrollback
        case "palette.toggleSplitZoom":
            return .toggleSplitZoom
        case "palette.equalizeSplits":
            return .equalizeSplits
        case "palette.resizePaneLeft":
            return .resizePaneLeft
        case "palette.resizePaneRight":
            return .resizePaneRight
        case "palette.resizePaneUp":
            return .resizePaneUp
        case "palette.resizePaneDown":
            return .resizePaneDown
        case "palette.triggerFlash":
            return .triggerFlash
        default:
            return nil
        }
    }

    func openCustomSidebarPane(_ name: String) {
        guard let workspace = tabManager.selectedWorkspace else {
            NSSound.beep()
            return
        }

        sidebarSelectionState.selection = .tabs
        workspace.clearSplitZoom()
        if let focusedPanelId = workspace.focusedPanelId,
           workspace.openOrFocusCustomSidebarSplit(from: focusedPanelId, name: name) != nil {
            return
        }
        guard let paneId = workspace.bonsplitController.focusedPaneId ?? workspace.bonsplitController.allPaneIds.first,
              workspace.openOrFocusCustomSidebarSurface(inPane: paneId, name: name, focus: true) != nil else {
            NSSound.beep()
            return
        }
    }

}

extension ContentView {
    /// Command palette entries for the pane-resize steps (upstream manaflow-ai/cmux#4025).
    static let paneResizePaletteCommands: [(
        commandId: String,
        action: KeyboardShortcutSettings.Action,
        keyword: String,
        direction: ResizeDirection
    )] = [
        ("palette.resizePaneLeft", .resizePaneLeft, "left", .left),
        ("palette.resizePaneRight", .resizePaneRight, "right", .right),
        ("palette.resizePaneUp", .resizePaneUp, "up", .up),
        ("palette.resizePaneDown", .resizePaneDown, "down", .down),
    ]
}
