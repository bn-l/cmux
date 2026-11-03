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
