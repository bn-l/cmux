internal import Foundation

/// The v1 line-protocol debug/test command dispatch (`set_shortcut`,
/// `simulate_shortcut`, `activate_app`, the counter reads/resets, the panel
/// snapshot/screenshot family, and `debug_right_sidebar_focus`).
///
/// Every command here was compiled only into DEBUG builds (the legacy
/// `processCommand` cases sat inside `#if DEBUG`), so the whole dispatch is
/// `#if DEBUG`-gated: in release builds ``handleDebugV1`` returns `nil` and the
/// app's legacy v1 dispatcher falls through to its own `default:` exactly as
/// the compiled-out cases produced.
///
/// Each forwards to the ``ControlDebugContext`` v1-shared witnesses, which run
/// the still-app-resident v1 string bodies and return their raw response
/// verbatim — byte-identical to the legacy dispatch.
extension ControlCommandCoordinator {
    /// Dispatches the v1 debug/test commands this coordinator owns; returns
    /// `nil` for anything else (and unconditionally in release builds) so the
    /// app's legacy v1 dispatcher can fall through.
    ///
    /// - Parameters:
    ///   - command: The lowercased v1 command token.
    ///   - args: The raw argument remainder of the command line.
    /// - Returns: The raw reply line, or `nil` if not owned here.
    public func handleDebugV1(command: String, args: String) -> String? {
#if DEBUG
        switch command {
        case "set_shortcut":
            return debugContext?.controlDebugSetShortcut(arguments: args)
                ?? Self.debugContextUnavailableResponse
        case "simulate_shortcut":
            return debugContext?.controlDebugSimulateShortcut(combo: args)
                ?? Self.debugContextUnavailableResponse
        case "activate_app":
            return debugContext?.controlDebugActivateApp()
                ?? Self.debugContextUnavailableResponse
        case "is_terminal_focused":
            return debugContext?.controlDebugIsTerminalFocused(surfaceArgument: args)
                ?? Self.debugContextUnavailableResponse
        case "read_terminal_text":
            return debugContext?.controlDebugReadTerminalText(surfaceArgument: args)
                ?? Self.debugContextUnavailableResponse
        case "render_stats":
            return debugContext?.controlDebugRenderStats(surfaceArgument: args)
                ?? Self.debugContextUnavailableResponse
        case "layout_debug":
            return debugContext?.controlDebugLayout()
                ?? Self.debugContextUnavailableResponse
        case "bonsplit_underflow_count":
            return debugContext?.controlDebugBonsplitUnderflowCount()
                ?? Self.debugContextUnavailableResponse
        case "reset_bonsplit_underflow_count":
            return debugContext?.controlDebugResetBonsplitUnderflowCount()
                ?? Self.debugContextUnavailableResponse
        case "empty_panel_count":
            return debugContext?.controlDebugEmptyPanelCount()
                ?? Self.debugContextUnavailableResponse
        case "reset_empty_panel_count":
            return debugContext?.controlDebugResetEmptyPanelCount()
                ?? Self.debugContextUnavailableResponse
        case "focus_notification":
            return debugContext?.controlDebugFocusNotification(arguments: args)
                ?? Self.debugContextUnavailableResponse
        case "flash_count":
            return debugContext?.controlDebugFlashCount(surfaceArgument: args)
                ?? Self.debugContextUnavailableResponse
        case "reset_flash_counts":
            return debugContext?.controlDebugResetFlashCounts()
                ?? Self.debugContextUnavailableResponse
        case "panel_snapshot":
            return debugContext?.controlDebugPanelSnapshot(arguments: args)
                ?? Self.debugContextUnavailableResponse
        case "panel_snapshot_reset":
            return debugContext?.controlDebugPanelSnapshotReset(surfaceArgument: args)
                ?? Self.debugContextUnavailableResponse
        case "screenshot":
            return debugContext?.controlDebugCaptureScreenshot(label: args)
                ?? Self.debugContextUnavailableResponse
        default:
            return nil
        }
#else
        return nil
#endif
    }

}
