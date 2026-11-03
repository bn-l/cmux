import Foundation

extension ShortcutStroke {
    /// Parses one stroke written in cmux.json, such as `"cmd+shift+t"`,
    /// `"ctrl + b"` or `"opt+left"`.
    ///
    /// The string is `+`-separated modifier names followed by one key. Case
    /// and whitespace around each part are ignored.
    /// - Modifiers: `cmd` / `command` / `⌘`, `shift` / `⇧`,
    ///   `opt` / `option` / `alt` / `⌥`, `ctrl` / `control` / `ctl` / `⌃`.
    /// - Key: a named key (`left`, `return`, `comma`, `playpause`, ...),
    ///   `f1` through `f20`, or a single character. A key part that is exactly
    ///   `" "` is the space key, so `"cmd+ "` is ⌘Space.
    ///
    /// The stroke has no `keyCode`. Whether it may start a binding without a
    /// modifier is decided by ``StoredShortcut/parseConfig(strokes:allowBareFirstStroke:)``.
    ///
    /// - Returns: The stroke, or `nil` when a modifier or the key is not recognized.
    public static func parseConfig(_ rawValue: String) -> ShortcutStroke? {
        let rawParts = rawValue.split(separator: "+", omittingEmptySubsequences: false).map(String.init)
        guard let rawKey = rawParts.last, let key = configKey(rawKey) else { return nil }
        let rawModifiers = rawParts.dropLast()
        let modifiers = rawModifiers.compactMap {
            configModifiersByName[$0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()]
        }
        guard modifiers.count == rawModifiers.count else { return nil }
        return ShortcutStroke(
            key: key,
            command: modifiers.contains(.command),
            shift: modifiers.contains(.shift),
            option: modifiers.contains(.option),
            control: modifiers.contains(.control)
        )
    }

    /// Decodes one stroke of the object form Settings writes:
    /// `{"key": "t", "command": true, "keyCode": 17}`.
    ///
    /// `key` is required and used as written. A modifier flag that is absent or
    /// `null` is `false`. `keyCode` is optional.
    ///
    /// - Returns: The stroke, or `nil` when `raw` is not an object, `key` is not
    ///   a string, a flag is not a JSON boolean, or `keyCode` is not an integer
    ///   in `0...65535`.
    static func decodeConfigObject(_ raw: Any) -> ShortcutStroke? {
        guard let object = raw as? [String: Any],
              let key = object["key"] as? String,
              let command = configFlag(object["command"]),
              let shift = configFlag(object["shift"]),
              let option = configFlag(object["option"]),
              let control = configFlag(object["control"]) else {
            return nil
        }
        let keyCode: UInt16?
        switch object["keyCode"] {
        case nil, is NSNull:
            keyCode = nil
        case let number as NSNumber where !isJSONBoolean(number):
            // An out-of-range or fractional code is corrupt, not a key to wrap
            // into UInt16 range, which would bind a different physical key.
            guard let exact = UInt16(exactly: number.doubleValue) else { return nil }
            keyCode = exact
        default:
            return nil
        }
        return ShortcutStroke(key: key, command: command, shift: shift, option: option, control: control, keyCode: keyCode)
    }

    /// A modifier flag: `false` when absent or `null`, `nil` when not a JSON boolean.
    private static func configFlag(_ raw: Any?) -> Bool? {
        switch raw {
        case nil, is NSNull: false
        case let number as NSNumber where isJSONBoolean(number): number.boolValue
        default: nil
        }
    }

    /// `JSONSerialization` returns both booleans and numbers as `NSNumber`.
    private static func isJSONBoolean(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private enum ConfigModifier {
        case command, shift, option, control
    }

    private static let configModifiersByName: [String: ConfigModifier] = [
        "cmd": .command, "command": .command, "⌘": .command,
        "shift": .shift, "⇧": .shift,
        "opt": .option, "option": .option, "alt": .option, "⌥": .option,
        "ctrl": .control, "control": .control, "ctl": .control, "⌃": .control,
    ]

    /// The lower-case names cmux.json accepts for each stored key token.
    private static let configKeyNames: [String: [String]] = [
        "←": ["left", "arrowleft", "leftarrow", "←"],
        "→": ["right", "arrowright", "rightarrow", "→"],
        "↑": ["up", "arrowup", "uparrow", "↑"],
        "↓": ["down", "arrowdown", "downarrow", "↓"],
        "\t": ["tab"],
        "\r": ["return", "enter", "↩"],
        "space": ["space", "spacebar", "<space>"],
        ",": ["comma"],
        ".": ["period", "dot"],
        "/": ["slash"],
        "\\": ["backslash"],
        ";": ["semicolon"],
        "'": ["quote", "apostrophe"],
        "`": ["backtick", "grave"],
        "-": ["minus", "hyphen"],
        "=": ["plus", "equals"],
        "[": ["leftbracket", "openbracket"],
        "]": ["rightbracket", "closebracket"],
        "media.volumeUp": ["volumeup", "mediavolumeup", "media.volumeup"],
        "media.volumeDown": ["volumedown", "mediavolumedown", "media.volumedown"],
        "media.brightnessUp": ["brightnessup", "mediabrightnessup", "media.brightnessup"],
        "media.brightnessDown": ["brightnessdown", "mediabrightnessdown", "media.brightnessdown"],
        "media.mute": ["mute", "mediamute", "media.mute"],
        "media.playPause": ["playpause", "mediaplaypause", "media.playpause"],
        "media.next": ["nexttrack", "medianext", "media.next", "media.nexttrack"],
        "media.previous": ["previoustrack", "mediaprevious", "media.previous", "media.previoustrack"],
    ]

    private static let configKeysByName = Dictionary(
        uniqueKeysWithValues: configKeyNames.flatMap { key, names in names.map { ($0, key) } }
    )

    /// The stored key token for the last `+`-separated part of a stroke.
    private static func configKey(_ rawKey: String) -> String? {
        let name = rawKey.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if name.isEmpty { return rawKey == " " ? "space" : nil }
        if let key = configKeysByName[name] { return key }
        if name.hasPrefix("f"), let number = Int(name.dropFirst()), (1...20).contains(number) {
            return "f\(number)"
        }
        return name.count == 1 ? name : nil
    }
}
