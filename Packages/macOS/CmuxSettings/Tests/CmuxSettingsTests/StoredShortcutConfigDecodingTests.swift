import CmuxSettings
import Foundation
import Testing

private func stroke(
    _ key: String,
    command: Bool = false,
    shift: Bool = false,
    option: Bool = false,
    control: Bool = false
) -> ShortcutStroke {
    ShortcutStroke(key: key, command: command, shift: shift, option: option, control: control)
}

/// Hand-written `shortcuts.bindings` values must decode exactly the way the app
/// applies them.
///
/// Users write bindings in cmux.json as strings (`"cmd+t"`), arrays of one or
/// two strings (`["ctrl+b", "%"]`) and `null`. Settings reads cmux.json through
/// ``StoredShortcut/decodeFromJSON(_:)``; when it rejects a form the app
/// accepts, the Settings row shows the default instead of what the app runs.
@Suite("StoredShortcut config grammar")
struct StoredShortcutConfigDecodingTests {
    /// Decodes `json` from the loose value `JSONSerialization` produces
    /// (NSString, NSArray, NSNull, ...), which is what ``JSONConfigStore``
    /// hands to the element type.
    private func decode(_ json: String) throws -> StoredShortcut? {
        let raw = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
        return StoredShortcut.decodeFromJSON(raw)
    }

    /// Encodes `value` as a JSON fragment, so string fixtures need no escaping.
    private func json(_ value: String) throws -> String {
        try #require(String(data: JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed), encoding: .utf8))
    }

    // MARK: - Strings

    @Test(arguments: [
        ("cmd+t", StoredShortcut(first: stroke("t", command: true))),
        ("cmd + t", StoredShortcut(first: stroke("t", command: true))),
        (" cmd+shift+T ", StoredShortcut(first: stroke("t", command: true, shift: true))),
        ("CMD+Ctrl+Alt+Shift+K", StoredShortcut(first: stroke("k", command: true, shift: true, option: true, control: true))),
        ("command+control+option+k", StoredShortcut(first: stroke("k", command: true, option: true, control: true))),
        ("⌘+⌃+⌥+⇧+k", StoredShortcut(first: stroke("k", command: true, shift: true, option: true, control: true))),
        ("ctl+k", StoredShortcut(first: stroke("k", control: true))),
        ("opt+k", StoredShortcut(first: stroke("k", option: true))),
        ("ctrl+%", StoredShortcut(first: stroke("%", control: true))),
        // Shift alone satisfies the first-stroke modifier rule.
        ("shift+t", StoredShortcut(first: stroke("t", shift: true))),
        // A raw " " after the last "+" is the space key.
        ("cmd+ ", StoredShortcut(first: stroke("space", command: true))),
        // Space is the one key allowed as a bare first stroke.
        (" ", StoredShortcut(first: stroke("space"))),
        ("space", StoredShortcut(first: stroke("space"))),
    ])
    func decodesAStringBinding(raw: String, expected: StoredShortcut) throws {
        #expect(try decode(try json(raw)) == expected, "\(raw.debugDescription) decoded wrong")
    }

    /// Every named-key token of the grammar, in mixed case.
    @Test(arguments: [
        ("left", "←"), ("ArrowLeft", "←"), ("leftarrow", "←"), ("←", "←"),
        ("right", "→"), ("arrowright", "→"), ("RightArrow", "→"), ("→", "→"),
        ("up", "↑"), ("arrowup", "↑"), ("uparrow", "↑"), ("↑", "↑"),
        ("down", "↓"), ("arrowdown", "↓"), ("DownArrow", "↓"), ("↓", "↓"),
        ("tab", "\t"), ("Tab", "\t"),
        ("return", "\r"), ("Enter", "\r"), ("↩", "\r"),
        ("space", "space"), ("SpaceBar", "space"), ("<space>", "space"), ("<Space>", "space"),
        ("comma", ","), ("period", "."), ("dot", "."), ("slash", "/"), ("backslash", "\\"),
        ("semicolon", ";"), ("quote", "'"), ("apostrophe", "'"), ("backtick", "`"), ("grave", "`"),
        ("minus", "-"), ("hyphen", "-"), ("plus", "="), ("equals", "="),
        ("leftbracket", "["), ("OpenBracket", "["), ("rightbracket", "]"), ("closebracket", "]"),
        ("volumeUp", "media.volumeUp"), ("mediavolumeup", "media.volumeUp"), ("media.volumeUp", "media.volumeUp"),
        ("volumedown", "media.volumeDown"), ("mediaVolumeDown", "media.volumeDown"), ("media.volumedown", "media.volumeDown"),
        ("brightnessup", "media.brightnessUp"), ("mediabrightnessup", "media.brightnessUp"), ("media.brightnessUp", "media.brightnessUp"),
        ("brightnessDown", "media.brightnessDown"), ("mediabrightnessdown", "media.brightnessDown"), ("media.brightnessdown", "media.brightnessDown"),
        ("mute", "media.mute"), ("mediamute", "media.mute"), ("Media.Mute", "media.mute"),
        ("playPause", "media.playPause"), ("mediaplaypause", "media.playPause"), ("media.playPause", "media.playPause"),
        ("nexttrack", "media.next"), ("medianext", "media.next"), ("media.next", "media.next"), ("media.nexttrack", "media.next"),
        ("previoustrack", "media.previous"), ("mediaprevious", "media.previous"), ("media.previous", "media.previous"),
        ("media.previoustrack", "media.previous"),
    ])
    func decodesANamedKey(token: String, key: String) throws {
        #expect(
            try decode(try json("cmd+\(token)")) == StoredShortcut(first: stroke(key, command: true)),
            "cmd+\(token) should decode to key \(key.debugDescription)"
        )
    }

    @Test(arguments: [
        ("cmd+f1", "f1"), ("cmd+F12", "f12"), ("ctrl+f20", "f20"), ("cmd+f05", "f5"),
    ])
    func decodesAFunctionKey(raw: String, key: String) throws {
        let decoded = try #require(try decode(try json(raw)), "\(raw) was rejected")
        #expect(decoded.first.key == key)
        #expect(decoded.first.hasAnyModifier)
        #expect(decoded.second == nil)
    }

    @Test(arguments: ["", "   ", "\t", "\n", " \t ", "none", "NONE", " None ", "clear", "Clear", "unbound", "UNBOUND", "disabled", "Disabled"])
    func decodesAnUnbindTokenAsUnbound(raw: String) throws {
        #expect(try decode(try json(raw)) == .unbound, "\(raw.debugDescription) is an unbind token")
    }

    @Test(arguments: [
        // No modifier on the first stroke (the default `allowBareFirstStroke: false`).
        "t", "%", "f5", "return", "left", "media.mute",
        // Malformed strokes.
        "cmd+bogus", "hyper+t", "cmd+", "+t", "cmd++", "cmd+tt", "cmd+f21", "cmd+f0", "cmd+shift+   ", "cmd+none",
    ])
    func rejectsAnInvalidString(raw: String) throws {
        #expect(try decode(try json(raw)) == nil, "\(raw.debugDescription) must not decode")
    }

    // MARK: - Arrays

    @Test func decodesATwoStrokeArrayAsAChord() throws {
        #expect(
            try decode(#"["ctrl+b", "%"]"#) == StoredShortcut(first: stroke("b", control: true), second: stroke("%"))
        )
        #expect(
            try decode(#"["cmd + k", " cmd+c"]"#)
                == StoredShortcut(first: stroke("k", command: true), second: stroke("c", command: true))
        )
        // The space exception lets space open a chord with no modifier.
        #expect(try decode(#"["space", "x"]"#) == StoredShortcut(first: stroke("space"), second: stroke("x")))
    }

    @Test func decodesAOneStrokeArrayLikeTheString() throws {
        #expect(try decode(#"["cmd+k"]"#) == StoredShortcut(first: stroke("k", command: true)))
        #expect(try decode(#"["none"]"#) == .unbound)
        #expect(try decode(#"[""]"#) == .unbound)
        #expect(try decode(#"[" "]"#) == StoredShortcut(first: stroke("space")))
    }

    @Test func decodesAnEmptyArrayAsUnbound() throws {
        #expect(try decode("[]") == .unbound)
    }

    @Test(arguments: [
        #"["ctrl+b", "x", "y"]"#,
        #"["cmd+a", "cmd+b", "cmd+c", "cmd+d"]"#,
        #"["b", "%"]"#,
        #"["g", "g"]"#,
        #"["ctrl+b", "none"]"#,
        #"["ctrl+b", ""]"#,
        #"["ctrl+b", "bogus"]"#,
        #"["ctrl+b", 5]"#,
        #"["ctrl+b", null]"#,
        #"[["ctrl+b"]]"#,
    ])
    func rejectsAnInvalidArray(json: String) throws {
        #expect(try decode(json) == nil, "\(json) must not decode")
    }

    // MARK: - null, absent and other shapes

    @Test func decodesNullAsUnbound() throws {
        #expect(try decode("null") == .unbound)
    }

    @Test func treatsAnAbsentValueAsNoBinding() {
        // nil means the key is absent, so the action keeps its default.
        #expect(StoredShortcut.decodeFromJSON(nil) == nil)
    }

    @Test(arguments: ["42", "true", "{}", #"{"key": "t", "command": true}"#, #"{"first": "cmd+t"}"#])
    func rejectsOtherShapes(json: String) throws {
        #expect(try decode(json) == nil, "\(json) must not decode")
    }

    @Test func stillDecodesTheObjectFormSettingsWrites() throws {
        let chord = StoredShortcut(
            first: ShortcutStroke(key: "b", control: true, keyCode: 11),
            second: ShortcutStroke(key: "%", shift: true)
        )
        let raw = try JSONSerialization.jsonObject(
            with: JSONSerialization.data(withJSONObject: chord.encodeForJSON())
        )
        #expect(StoredShortcut.decodeFromJSON(raw) == chord)
        #expect(try decode(#"{"first": {"key": "", "command": false, "shift": false, "option": false, "control": false}}"#) == .unbound)
    }

    // MARK: - Object form written by hand

    @Test(arguments: [
        // Absent and null flags are false, as in the schema and the app.
        (#"{"first": {"key": "t", "command": true}}"#, StoredShortcut(first: stroke("t", command: true))),
        (#"{"first": {"key": "t", "shift": true, "option": null}}"#, StoredShortcut(first: stroke("t", shift: true))),
        (#"{"first": {"key": "space"}}"#, StoredShortcut(first: stroke("space"))),
        (#"{"first": {"key": "b", "control": true}, "second": {"key": "%"}}"#,
         StoredShortcut(first: stroke("b", control: true), second: stroke("%"))),
        (#"{"first": {"key": "b", "control": true}, "second": null}"#, StoredShortcut(first: stroke("b", control: true))),
        (#"{"first": {"key": "k", "command": true, "keyCode": 40}}"#,
         StoredShortcut(first: ShortcutStroke(key: "k", command: true, keyCode: 40))),
        (#"{"first": {"key": "k", "command": true, "keyCode": 65535}}"#,
         StoredShortcut(first: ShortcutStroke(key: "k", command: true, keyCode: 65535))),
        // An empty first key unbinds, whatever follows.
        (#"{"first": {"key": ""}}"#, .unbound),
        (#"{"first": {"key": ""}, "second": {"key": "x"}}"#, .unbound),
    ])
    func decodesAHandWrittenObject(json: String, expected: StoredShortcut) throws {
        #expect(try decode(json) == expected, "\(json) decoded wrong")
    }

    @Test(arguments: [
        // Bare first stroke for an action that needs a modifier.
        #"{"first": {"key": "t"}}"#,
        #"{"first": {"key": "t", "command": false}}"#,
        // Flags and key codes of the wrong type or range.
        #"{"first": {"key": "t", "command": "true"}}"#,
        #"{"first": {"key": "t", "command": 1}}"#,
        #"{"first": {"key": "t", "command": true, "keyCode": 65536}}"#,
        #"{"first": {"key": "t", "command": true, "keyCode": -1}}"#,
        #"{"first": {"key": "t", "command": true, "keyCode": 1.5}}"#,
        #"{"first": {"key": "t", "command": true, "keyCode": true}}"#,
        #"{"first": {"key": "t", "command": true, "keyCode": "17"}}"#,
        #"{"first": {"key": 5, "command": true}}"#,
        #"{"first": {"command": true}}"#,
        #"{"first": null}"#,
        // A bad second stroke rejects the chord instead of dropping half of it.
        #"{"first": {"key": "b", "control": true}, "second": {"key": ""}}"#,
        #"{"first": {"key": "b", "control": true}, "second": {"key": "x", "shift": "yes"}}"#,
        #"{"first": {"key": "b", "control": true}, "second": "x"}"#,
    ])
    func rejectsAnInvalidObject(json: String) throws {
        #expect(try decode(json) == nil, "\(json) must not decode")
    }

    @Test func objectBareFirstStrokeFollowsTheAction() throws {
        let raw = try JSONSerialization.jsonObject(with: Data(#"{"first": {"key": "n"}}"#.utf8))
        #expect(StoredShortcut.decodeFromJSON(raw, entryKey: "diffViewerScrollDown") == StoredShortcut(first: stroke("n")))
        #expect(StoredShortcut.decodeFromJSON(raw, entryKey: "newTab") == nil)
        #expect(StoredShortcut.decodeFromJSON(raw, entryKey: "notAnAction") == nil)
    }

    // MARK: - Per-action rules

    @Test(arguments: [
        // Numbered actions store the digit as the "1" placeholder.
        ("selectWorkspaceByNumber", #""ctrl+5""#, StoredShortcut(first: stroke("1", control: true))),
        ("selectSurfaceByNumber", #"["ctrl+b", "7"]"#, StoredShortcut(first: stroke("b", control: true), second: stroke("1"))),
        ("selectWorkspaceByNumber", #"{"first": {"key": "9", "command": true, "keyCode": 25}}"#,
         StoredShortcut(first: ShortcutStroke(key: "1", command: true, keyCode: 25))),
        ("selectWorkspaceByNumber", "null", .unbound),
        // System-wide hotkeys: one stroke with cmd, opt or ctrl.
        ("globalSearch", #""cmd+opt+f""#, StoredShortcut(first: stroke("f", command: true, option: true))),
        ("globalSearch", #""ctrl+space""#, StoredShortcut(first: stroke("space", control: true))),
        // Show/hide keeps a binding it cannot register, so Settings shows it.
        ("showHideAllWindows", #""shift+a""#, StoredShortcut(first: stroke("a", shift: true))),
        ("showHideAllWindows", #"["cmd+k", "cmd+h"]"#, StoredShortcut(first: stroke("k", command: true), second: stroke("h", command: true))),
        ("cycleTextBoxSubmitAction", #""shift+tab""#, StoredShortcut(first: stroke("\t", shift: true))),
        ("cycleTextBoxSubmitAction", "[]", .unbound),
    ])
    func appliesTheActionRules(id: String, json: String, expected: StoredShortcut) throws {
        let raw = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
        #expect(StoredShortcut.decodeFromJSON(raw, entryKey: id) == expected, "\(id): \(json)")
    }

    @Test(arguments: [
        ("selectWorkspaceByNumber", #""ctrl+0""#),
        ("selectWorkspaceByNumber", #""cmd+a""#),
        ("selectSurfaceByNumber", #"["ctrl+b", "x"]"#),
        ("globalSearch", #""shift+f""#),
        ("globalSearch", #"["cmd+k", "cmd+f"]"#),
        ("cycleTextBoxSubmitAction", #"["ctrl+b", "tab"]"#),
    ])
    func rejectsWhatTheActionRejects(id: String, json: String) throws {
        let raw = try JSONSerialization.jsonObject(with: Data(json.utf8), options: .fragmentsAllowed)
        #expect(StoredShortcut.decodeFromJSON(raw, entryKey: id) == nil, "\(id) must reject \(json)")
    }

    // MARK: - Per-action bare first strokes, read through the store

    private func makeStore(bindings: String) throws -> (JSONConfigStore, SettingCatalog) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-shortcut-grammar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        try Data(#"{"shortcuts": {"bindings": \#(bindings)}}"#.utf8).write(to: fileURL)
        return (JSONConfigStore(fileURL: fileURL), SettingCatalog())
    }

    @Test func bareFirstStrokesDecodeOnlyForActionsThatAllowThem() async throws {
        // Arrange: every action bound to a bare "n", plus an unknown id.
        let ids = ShortcutAction.allCases.map(\.rawValue) + ["notAnAction"]
        let object = Dictionary(uniqueKeysWithValues: ids.map { ($0, "n") })
        let bindings = try #require(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
        let (store, _) = try makeStore(bindings: bindings)

        // Act
        let entries = await store.shortcutBindings()

        // Assert
        let expectedIds = Set(ShortcutAction.allCases.filter(\.allowsBareFirstStroke).map(\.rawValue))
        try #require(!expectedIds.isEmpty, "no action allows a bare first stroke, so this test checks nothing")
        #expect(Set(entries.keys) == expectedIds)
        for id in expectedIds {
            #expect(entries[id] == StoredShortcut(first: stroke("n")), "\(id)")
        }
    }

    @Test func bareChordDecodesForAnActionThatAllowsIt() async throws {
        // Arrange: the diff viewer's own default is the bare chord g g.
        let (store, _) = try makeStore(bindings: #"""
        {"diffViewerScrollToTop": ["g", "g"], "splitRight": ["g", "g"], "diffViewerOpenFileSearch": "/"}
        """#)

        // Act
        let entries = await store.shortcutBindings()

        // Assert
        #expect(entries == [
            "diffViewerScrollToTop": try #require(ShortcutAction.diffViewerScrollToTop.defaultShortcut),
            "diffViewerOpenFileSearch": StoredShortcut(first: stroke("/")),
        ])
    }

    @Test func wholeObjectReadAlsoUsesTheActionId() async throws {
        // Arrange
        let (store, catalog) = try makeStore(bindings: #"""
        {"diffViewerScrollDown": "n", "newTab": "cmd+t", "closeWindow": null, "splitRight": ["ctrl+b", "%"]}
        """#)

        // Act
        let bindings = await store.value(for: catalog.shortcuts.bindings)

        // Assert
        #expect(bindings == [
            "diffViewerScrollDown": StoredShortcut(first: stroke("n")),
            "newTab": StoredShortcut(first: stroke("t", command: true)),
            "closeWindow": .unbound,
            "splitRight": StoredShortcut(first: stroke("b", control: true), second: stroke("%")),
        ])
    }
}
