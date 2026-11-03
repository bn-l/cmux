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
}
