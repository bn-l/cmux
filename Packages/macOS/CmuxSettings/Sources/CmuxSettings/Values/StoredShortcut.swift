import Foundation

/// A shortcut binding as it lives on disk: one or two ``ShortcutStroke``s.
///
/// A single-stroke binding fires when the user presses the recorded
/// modifiers + key. A two-stroke ("chord") binding is the tmux-style
/// prefix pattern: press the first stroke, then the second within a
/// short window. ``isUnbound`` represents an explicit "no shortcut for
/// this action" assignment so users can suppress an inherited default.
public struct StoredShortcut: Sendable, Equatable, Hashable, Codable, SettingCodable {
    /// The primary stroke. Empty `key` means the shortcut is unbound.
    public let first: ShortcutStroke

    /// Optional second stroke (chord). `nil` means single-stroke.
    public let second: ShortcutStroke?

    /// A binding that explicitly clears any inherited default.
    public static let unbound = StoredShortcut(
        first: ShortcutStroke(key: "")
    )

    public init(first: ShortcutStroke, second: ShortcutStroke? = nil) {
        self.first = first
        self.second = second
    }

    /// True when this binding is the explicit "no shortcut" marker.
    public var isUnbound: Bool { first.key.isEmpty && second == nil }

    /// True when the binding fires on two consecutive strokes.
    public var hasChord: Bool { second != nil }

    // MARK: - SettingCodable

    public static func decodeFromUserDefaults(_ raw: Any?) -> StoredShortcut? {
        guard let data = raw as? Data else { return nil }
        return try? JSONDecoder().decode(StoredShortcut.self, from: data)
    }

    public func encodeForUserDefaults() -> Any {
        (try? JSONEncoder().encode(self)) ?? Data()
    }

    /// Decodes a binding in any cmux.json form (see
    /// ``decodeFromJSON(_:allowBareFirstStroke:)``) without knowing its action,
    /// so a string or array binding needs a modifier on its first stroke.
    public static func decodeFromJSON(_ raw: Any?) -> StoredShortcut? {
        decodeFromJSON(raw, allowBareFirstStroke: false)
    }

    /// Decodes the binding whose key is `entryKey`, an action id, the way
    /// cmux applies it: the first stroke may be bare only when the action's
    /// ``ShortcutAction/allowsBareFirstStroke`` is `true`, and the result goes
    /// through ``ShortcutAction/normalizedConfigBinding(_:)``. An unknown id
    /// gets the strict bare-stroke rule and no per-action rules.
    public static func decodeFromJSON(_ raw: Any?, entryKey: String) -> StoredShortcut? {
        guard let action = ShortcutAction(rawValue: entryKey) else {
            return decodeFromJSON(raw, allowBareFirstStroke: false)
        }
        return decodeFromJSON(raw, allowBareFirstStroke: action.allowsBareFirstStroke)
            .flatMap(action.normalizedConfigBinding)
    }

    public func encodeForJSON() -> Any {
        guard let data = try? JSONEncoder().encode(self),
              let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return NSNull()
        }
        return object
    }
}
