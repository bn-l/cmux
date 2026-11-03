/// Keyboard-shortcut action ordering used by Settings UI surfaces.
public extension ShortcutAction {
    /// Actions shown in the Keyboard Shortcuts settings section, in display order.
    static var settingsVisibleActions: [ShortcutAction] {
        allCases.filter { $0 != .showHideAllWindows }
    }
}
