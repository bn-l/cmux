import Foundation

/// Where cmux.json's `shortcuts` object holds bindings, and which one applies.
///
/// A binding lives in `shortcuts.bindings.<actionId>`, or directly in
/// `shortcuts.<actionId>`. When both exist the direct entry applies. The app's
/// settings-file store, the Settings window (through
/// ``JSONConfigStore/shortcutBindings()``) and the CLI's diff viewer all
/// resolve bindings here, so they agree on what each action is bound to.
public enum ShortcutConfigBindings {
    /// `shortcuts` keys that hold settings rather than a binding.
    public static let settingKeys: Set<String> = ["bindings", "showModifierHoldHints", "when"]

    /// Every raw binding in the `shortcuts` object `section`, by key:
    /// `bindings` entries overlaid by direct entries. Keys that are not
    /// action ids are kept, so callers can report them.
    public static func rawBindings(inShortcutsSection section: [String: Any]) -> [String: Any] {
        (section["bindings"] as? [String: Any] ?? [:])
            .merging(section.filter { !settingKeys.contains($0.key) }) { _, direct in direct }
    }

    /// The binding cmux applies for each action that `section` binds, by
    /// action id, decoded by ``StoredShortcut/decodeFromJSON(_:entryKey:)``.
    /// Invalid bindings and unknown ids are left out, so those actions keep
    /// their defaults.
    public static func bindings(inShortcutsSection section: [String: Any]) -> [String: StoredShortcut] {
        let raw = rawBindings(inShortcutsSection: section)
        return ShortcutAction.allCases.reduce(into: [:]) { bindings, action in
            bindings[action.rawValue] = raw[action.rawValue].flatMap {
                StoredShortcut.decodeFromJSON($0, entryKey: action.rawValue)
            }
        }
    }

    static let sectionPath = JSONPath(dottedPath: "shortcuts")

    /// Writes `shortcut` as `action`'s binding at the entry cmux applies:
    /// `shortcuts.<actionId>` when `root` has one, otherwise
    /// `shortcuts.bindings.<actionId>`. Every other entry stays as written.
    static func assign(_ shortcut: StoredShortcut, for action: ShortcutAction, in root: inout [String: Any]) {
        let direct = sectionPath.appending(action.rawValue)
        let path = direct.lookup(in: root) != nil
            ? direct
            : KeyboardShortcutsCatalogSection().bindings.path.appending(action.rawValue)
        path.assign(shortcut.encodeForJSON(), in: &root)
    }

    /// Removes every action's binding from `root`: `shortcuts.bindings`
    /// becomes empty and direct `shortcuts.<actionId>` entries are deleted.
    /// `showModifierHoldHints`, `when` and keys that are not action ids stay.
    static func removeAll(in root: inout [String: Any]) {
        for action in ShortcutAction.allCases {
            sectionPath.appending(action.rawValue).remove(in: &root)
        }
        KeyboardShortcutsCatalogSection().bindings.path.assign([String: Any](), in: &root)
    }
}
