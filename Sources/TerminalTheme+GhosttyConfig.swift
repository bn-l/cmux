import CMUXMobileCore
import CmuxFoundation
import CmuxTerminalCore
import Foundation

extension TerminalTheme {
    /// Builds a ``TerminalTheme`` from the Mac's resolved terminal config.
    ///
    /// `GhosttyConfig.load()` already folds a named `theme = <name>` directive
    /// (any of ghostty's bundled themes, e.g. `catppuccin-mocha`), cmux's managed
    /// default appearance, and the user's explicit `background=`/`palette=`
    /// overrides into concrete `NSColor`s, so reading those resolved colors here
    /// captures the *effective* palette for both custom configs and named ghostty
    /// themes. Any palette index the config did not populate falls back to the
    /// matching Monokai entry so consumers always receive a complete 16-color
    /// palette.
    ///
    /// Used by the AgentChat theme sync to push the live terminal appearance to
    /// the AgentChat sidecar.
    init(ghosttyConfig config: GhosttyConfig) {
        let monokai = TerminalTheme.monokai
        let palette: [String] = (0...15).map { index in
            config.palette[index]?.hexString() ?? monokai.palette[index]
        }
        // Only carry cursor-text when the Mac config actually parsed a
        // `cursor-text` directive. When it did not, `config.cursorTextColor` is
        // just a placeholder default that ghostty never applies (it derives
        // cursor-text contrast automatically), so forwarding it would emit an
        // explicit `cursor-text` line the Mac never had and mis-color the cursor
        // label. `nil` here lets the consumer derive contrast too.
        let cursorText = config.hasParsedCursorTextColor ? config.cursorTextColor.hexString() : nil
        self.init(
            background: config.backgroundColor.hexString(),
            foreground: config.foregroundColor.hexString(),
            cursor: config.cursorColor.hexString(),
            cursorText: cursorText,
            selectionBackground: config.selectionBackground.hexString(),
            selectionForeground: config.selectionForeground.hexString(),
            palette: palette
        )
    }
}
