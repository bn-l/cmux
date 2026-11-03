import Foundation

/// The binding forms users write by hand in cmux.json's `shortcuts.bindings`.
///
/// This is the one implementation of that grammar. The app's settings-file
/// store applies bindings through it, and ``decodeFromJSON(_:)`` reads them
/// through it, so the Settings window shows what the app runs.
extension StoredShortcut {
    /// Parses a binding written as one string: a stroke such as `"cmd+t"`
    /// (see ``ShortcutStroke/parseConfig(_:)``), or an unbind token
    /// (see ``isUnboundConfigToken(_:)``) for ``unbound``.
    ///
    /// The first-stroke rule of ``parseConfig(strokes:allowBareFirstStroke:)`` applies.
    public static func parseConfig(_ rawValue: String, allowBareFirstStroke: Bool = false) -> StoredShortcut? {
        parseConfig(strokes: [rawValue], allowBareFirstStroke: allowBareFirstStroke)
    }

    /// Parses a binding written as one or two stroke strings. Two strokes are
    /// a chord, such as `["ctrl+b", "%"]`. A single unbind token is ``unbound``.
    ///
    /// The first stroke needs a modifier unless its key is space or
    /// `allowBareFirstStroke` is `true`. Pass
    /// ``ShortcutAction/allowsBareFirstStroke`` for the action being bound.
    ///
    /// - Returns: The binding, or `nil` for no strokes or more than two, a
    ///   stroke that does not parse, or a bare first stroke that is not allowed.
    public static func parseConfig(strokes: [String], allowBareFirstStroke: Bool = false) -> StoredShortcut? {
        guard (1...2).contains(strokes.count) else { return nil }
        if strokes.count == 1, isUnboundConfigToken(strokes[0]) { return .unbound }
        let parsed = strokes.compactMap(ShortcutStroke.parseConfig)
        guard parsed.count == strokes.count,
              let first = parsed.first,
              allowBareFirstStroke || first.hasAnyModifier || first.key == "space" else {
            return nil
        }
        return StoredShortcut(first: first, second: parsed.dropFirst().first)
    }

    /// Whether `rawValue` unbinds the action: an empty or whitespace-only
    /// string, or `none`, `clear`, `unbound` or `disabled` in any case. A
    /// string that is exactly `" "` is the space key, not an unbind token.
    public static func isUnboundConfigToken(_ rawValue: String) -> Bool {
        rawValue != " "
            && unboundConfigTokens.contains(rawValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    private static let unboundConfigTokens: Set<String> = ["", "none", "clear", "unbound", "disabled"]

    /// Decodes a `shortcuts.bindings` value in any form cmux.json accepts:
    /// - JSON `null`: ``unbound``.
    /// - A string: ``parseConfig(_:allowBareFirstStroke:)``.
    /// - An array of strings: `[]` is ``unbound``; otherwise
    ///   ``parseConfig(strokes:allowBareFirstStroke:)``.
    /// - An object: the `{"first": {...}, "second": {...}}` form Settings
    ///   writes, decoded as written. `allowBareFirstStroke` does not apply.
    ///
    /// - Parameter raw: A value from `JSONSerialization`, or `nil` when the
    ///   binding is absent.
    /// - Returns: The binding, or `nil` when `raw` is absent or invalid.
    public static func decodeFromJSON(_ raw: Any?, allowBareFirstStroke: Bool) -> StoredShortcut? {
        switch raw {
        case is NSNull:
            return .unbound
        case let string as String:
            return parseConfig(string, allowBareFirstStroke: allowBareFirstStroke)
        case let strokes as [String]:
            return strokes.isEmpty ? .unbound : parseConfig(strokes: strokes, allowBareFirstStroke: allowBareFirstStroke)
        case let object as [String: Any]:
            guard let data = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            return try? JSONDecoder().decode(StoredShortcut.self, from: data)
        default:
            return nil
        }
    }
}
