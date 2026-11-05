import AppKit
import CmuxTerminalCore

extension GhosttyNSView {
    func terminalPointerShouldForwardActivation() -> Bool {
        guard let terminalSurface else { return false }
        guard desiredFocus else { return false }

        return TerminalPointerFocusActivationPolicy().shouldForwardToTerminal(
            currentPanelId: terminalSurface.id,
            focusedPanelId: terminalSurface.owningWorkspace()?.focusedPanelId
        )
    }

    /// AppKit moves first responder during window dispatch, so by the time `mouseDown` runs this
    /// panel already counts as focused. The window's first-responder guard calls this first, while
    /// the panel's earlier focus state is still readable. A focus click must not reach the program:
    /// with mouse reporting on, any pointer drift during the press becomes a drag (nvim enters Visual).
    /// Command-clicks stay forwarded so links and paths in an unfocused pane still open on the first click.
    func notePointerFocusTransferBeforeResponderChange(for event: NSEvent) {
        guard event.type == .leftMouseDown,
              !event.modifierFlags.contains(.command),
              !terminalPointerShouldForwardActivation() else { return }
        pointerFocusTransferEventTimestamp = event.timestamp
    }

    /// Matching on the event keeps a press that never reached `mouseDown` from swallowing a later click.
    func takePointerFocusTransfer(for event: NSEvent) -> Bool {
        defer { pointerFocusTransferEventTimestamp = nil }
        return pointerFocusTransferEventTimestamp == event.timestamp
    }
}
