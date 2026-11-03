import Foundation

/// Per-action rules for a binding read from cmux.json. The app target applies
/// the same rules in `KeyboardShortcutSettings.Action.normalizedSettingsFileShortcut`,
/// plus one check this package cannot make: a system-wide hotkey's key must
/// exist on the current keyboard layout.
extension ShortcutAction {
    /// The binding cmux applies when cmux.json binds this action to `shortcut`,
    /// or `nil` when the action rejects it and keeps its default.
    ///
    /// - ``StoredShortcut/unbound`` stays unbound.
    /// - A chord is rejected unless ``allowsChordShortcut``.
    /// - ``globalSearch`` and ``showHideAllWindows`` are system-wide hotkeys:
    ///   one stroke with ⌘, ⌥ or ⌃. ``globalSearch`` rejects anything else.
    ///   ``showHideAllWindows`` keeps it, so Settings shows the binding the
    ///   user wrote even though the hotkey cannot be registered.
    /// - Numbered actions go through ``normalizingNumberedDigit(_:)``.
    public func normalizedConfigBinding(_ shortcut: StoredShortcut) -> StoredShortcut? {
        if shortcut.isUnbound { return .unbound }
        if shortcut.hasChord, !allowsChordShortcut { return nil }
        switch self {
        case .globalSearch, .showHideAllWindows:
            let first = shortcut.first
            let registrable = !shortcut.hasChord && (first.command || first.option || first.control)
            return registrable || self == .showHideAllWindows ? shortcut : nil
        default:
            return normalizingNumberedDigit(shortcut)
        }
    }

    /// For a numbered action (``usesNumberedDigitMatching``), checks that the
    /// digit stroke (the chord's second stroke, else the only one) is a digit
    /// 1–9 and stores it as `"1"`, the placeholder for the whole range. Other
    /// actions get `shortcut` back unchanged.
    ///
    /// - Returns: The binding, or `nil` when a numbered action's digit stroke
    ///   is not 1–9.
    public func normalizingNumberedDigit(_ shortcut: StoredShortcut) -> StoredShortcut? {
        guard usesNumberedDigitMatching else { return shortcut }
        let digitStroke = shortcut.second ?? shortcut.first
        guard let digit = Int(digitStroke.key), (1...9).contains(digit) else { return nil }
        let placeholder = ShortcutStroke(
            key: "1",
            command: digitStroke.command,
            shift: digitStroke.shift,
            option: digitStroke.option,
            control: digitStroke.control,
            keyCode: digitStroke.keyCode
        )
        return shortcut.hasChord
            ? StoredShortcut(first: shortcut.first, second: placeholder)
            : StoredShortcut(first: placeholder)
    }
}
