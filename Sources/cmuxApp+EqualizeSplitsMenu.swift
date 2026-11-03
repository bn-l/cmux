import AppKit
import CmuxPanes
import SwiftUI

extension cmuxApp {
    func equalizeSplitsCommandButton() -> some View {
        splitCommandButton(title: String(localized: "command.equalizeSplits.title", defaultValue: "Equalize Splits"), shortcut: menuShortcut(for: .equalizeSplits)) {
            let manager = activeTabManager
            if let workspace = manager.selectedWorkspace {
                let didEqualize = manager.equalizeSplits(tabId: workspace.id)
#if DEBUG
                if !didEqualize {
                    cmuxDebugLog("menu.equalizeSplits result=noSplitOrFailed workspaceId=\(workspace.id)")
                }
#endif
            }
        }
    }

    /// Equalize Splits plus the four pane-resize steps.
    @ViewBuilder
    func paneSizingCommandButtons() -> some View {
        equalizeSplitsCommandButton()
        ForEach(Self.paneResizeMenuItems, id: \.action) { item in
            splitCommandButton(title: item.action.label, shortcut: menuShortcut(for: item.action)) {
                if AppDelegate.shared?.performResizePaneShortcut(direction: item.direction) != true {
                    NSSound.beep()
                }
            }
        }
    }

    private static let paneResizeMenuItems: [(action: KeyboardShortcutSettings.Action, direction: ResizeDirection)] = [
        (.resizePaneLeft, .left),
        (.resizePaneRight, .right),
        (.resizePaneUp, .up),
        (.resizePaneDown, .down),
    ]
}
