import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

/// One shortcut edit made in the Settings window, applied through the same
/// ``ShortcutListModel`` entry point the row's recorder or X/restore button uses.
enum SettingsShortcutEdit: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case recordStroke
    case recordChord
    case clear
    case restore

    var testDescription: String { rawValue }

    /// The action this edit changes. None of these actions has a hand-written entry.
    var action: ShortcutAction {
        switch self {
        case .recordStroke, .recordChord: .openSettings
        case .clear, .restore: .toggleFullScreen
        }
    }

    /// The binding the edit must leave on disk for ``action``. Four-modifier
    /// first strokes collide with no default, so no edit is rejected as a conflict.
    var expected: StoredShortcut {
        switch self {
        case .recordStroke:
            StoredShortcut(first: ShortcutStroke(key: "j", command: true, shift: true, option: true, control: true))
        case .recordChord:
            StoredShortcut(
                first: ShortcutStroke(key: "j", command: true, shift: true, option: true, control: true),
                second: ShortcutStroke(key: "k", command: true)
            )
        case .clear:
            .unbound
        case .restore:
            StoredShortcut(first: ShortcutStroke(key: "g", command: true, shift: true, option: true, control: true))
        }
    }

    @MainActor
    func perform(on model: ShortcutListModel) async {
        switch self {
        case .recordStroke:
            await model.assign(stroke: expected.first, to: action)
        case .recordChord:
            await model.assignChord(expected, to: action)
        case .clear:
            // toggleFullScreen has a default (⌃⌘F), so the X button clears it.
            await model.clearOrRestore(for: action)
        case .restore:
            // The restore branch of the X/restore button.
            await model.restoreBinding(expected, for: action)
        }
    }
}

/// Shortcut bindings the user wrote by hand in cmux.json. The app accepts
/// string (`"cmd+t"`), array (`["ctrl+b", "%"]`) and `null` bindings next to the
/// object form Settings writes. Settings must show them as the app applies them,
/// use them for conflict detection and the X/restore button, and never rewrite
/// an entry the user did not edit in Settings.
@MainActor
@Suite struct ShortcutListModelHandWrittenBindingsTests {

    /// Hand-written `shortcuts.bindings` entries. `newWindow` (a bare first
    /// stroke on an action that needs a modifier) and `quit` (three strokes)
    /// are invalid, so the app ignores them and keeps the defaults.
    private static let handWrittenBindingsJSON = #"""
    {
      "newTab": "cmd+t",
      "splitRight": ["ctrl+b", "%"],
      "closeWindow": null,
      "toggleSidebar": " Disabled ",
      "find": "cmd + shift + f5",
      "diffViewerScrollDown": "n",
      "newWindow": "n",
      "quit": ["cmd+k", "cmd+q", "cmd+x"]
    }
    """#

    /// The bindings the app applies for ``handWrittenBindingsJSON``.
    private static let handWrittenAsApplied: [String: StoredShortcut] = [
        "newTab": StoredShortcut(first: ShortcutStroke(key: "t", command: true)),
        "splitRight": StoredShortcut(first: ShortcutStroke(key: "b", control: true), second: ShortcutStroke(key: "%")),
        "closeWindow": .unbound,
        "toggleSidebar": .unbound,
        "find": StoredShortcut(first: ShortcutStroke(key: "f5", command: true, shift: true)),
        "diffViewerScrollDown": StoredShortcut(first: ShortcutStroke(key: "n")),
    ]

    /// A binding recorded in Settings earlier, stored in the object form the package decodes.
    private static let settingsWritten = StoredShortcut(
        first: ShortcutStroke(key: "u", command: true, shift: true, option: true, control: true)
    )

    private func handWrittenBindings() throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(Self.handWrittenBindingsJSON.utf8)) as? [String: Any]
        )
    }

    /// Writes a cmux.json holding the hand-written bindings, any `settingsWritten`
    /// object-form bindings, and an unrelated `app` setting.
    private func makeConfigFile(settingsWritten: [String: StoredShortcut] = [:]) throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-hand-written-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json")
        let bindings = try handWrittenBindings().merging(settingsWritten.mapValues { $0.encodeForJSON() }) { $1 }
        let root: [String: Any] = ["app": ["appearance": "dark"], "shortcuts": ["bindings": bindings]]
        try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted]).write(to: fileURL)
        return fileURL
    }

    private func spin(until condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(condition(), "spin(until:) timed out after 100 000 yields")
    }

    private func expectHandWrittenBindingsUnchanged(
        _ onDisk: [String: Any],
        sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let handWritten = try handWrittenBindings()
        let remaining = onDisk.filter { handWritten.keys.contains($0.key) }
        #expect(
            NSDictionary(dictionary: remaining).isEqual(to: handWritten),
            "hand-written bindings changed. Expected \(handWritten), found \(remaining)",
            sourceLocation: sourceLocation
        )
    }

    /// The raw `shortcuts.bindings` object currently on disk.
    private func bindingsOnDisk(_ fileURL: URL) throws -> [String: Any] {
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any],
            "cmux.json is not a JSON object"
        )
        let shortcuts = try #require(root["shortcuts"] as? [String: Any], "cmux.json lost its shortcuts object")
        return try #require(shortcuts["bindings"] as? [String: Any], "cmux.json lost shortcuts.bindings")
    }

    @Test(arguments: SettingsShortcutEdit.allCases)
    func settingsEditKeepsHandWrittenBindings(_ edit: SettingsShortcutEdit) async throws {
        // Arrange
        let fileURL = try makeConfigFile()
        let catalog = SettingCatalog()
        let store = JSONConfigStore(fileURL: fileURL)
        let model = ShortcutListModel(jsonStore: store, catalog: catalog, errorLog: SettingsErrorLog())
        model.startObserving()
        // No wait for the first stream delivery: the write must not depend on
        // whether the model has decoded the hand-written entries yet.

        // Act
        await edit.perform(on: model)

        // Assert
        let onDisk = try bindingsOnDisk(fileURL)
        let written = onDisk[edit.action.rawValue]
        #expect(
            StoredShortcut.decodeFromJSON(written) == edit.expected,
            "\(edit.action.rawValue) on disk: \(String(describing: written))"
        )
        try expectHandWrittenBindingsUnchanged(onDisk)
        let expectedKeys = Set(try handWrittenBindings().keys).union([edit.action.rawValue])
        #expect(Set(onDisk.keys) == expectedKeys, "unexpected entries on disk: \(onDisk.keys.sorted())")
        let root = try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any]
        #expect((root?["app"] as? [String: Any])?["appearance"] as? String == "dark")
    }

    @Test func modelShowsSettingsWrittenBindingsNextToHandWrittenOnes() async throws {
        // WHY: once hand-written entries survive Settings writes, the file mixes
        // forms for good. A whole-dictionary decode fails on that mix and hides
        // every binding the user recorded in Settings, so the rows fall back to
        // the defaults.

        // Arrange
        let action = ShortcutAction.openSettings
        let fileURL = try makeConfigFile(settingsWritten: [action.rawValue: Self.settingsWritten])
        let store = JSONConfigStore(fileURL: fileURL)
        let model = ShortcutListModel(jsonStore: store, catalog: SettingCatalog(), errorLog: SettingsErrorLog())

        // Act
        model.startObserving()
        await spin(until: { model.bindings[action.rawValue] != nil })

        // Assert
        #expect(model.bindings == Self.handWrittenAsApplied.merging([action.rawValue: Self.settingsWritten]) { $1 })
        #expect(model.effective(for: action) == Self.settingsWritten)
    }

    @Test func modelShowsHandWrittenBindingsAsTheAppAppliesThem() async throws {
        // WHY: the package used to decode only the object form, so every
        // string, array and null binding showed as its default in Settings
        // while the app ran the hand-written one.

        // Arrange: the Settings-written entry is decoded both before and after
        // the fix, so waiting for it waits for the first stream delivery.
        let syncAction = ShortcutAction.openSettings
        let fileURL = try makeConfigFile(settingsWritten: [syncAction.rawValue: Self.settingsWritten])
        let store = JSONConfigStore(fileURL: fileURL)
        let model = ShortcutListModel(jsonStore: store, catalog: SettingCatalog(), errorLog: SettingsErrorLog())

        // Act
        model.startObserving()
        await spin(until: { model.bindings[syncAction.rawValue] != nil })

        // Assert
        let expected = Self.handWrittenAsApplied.merging([syncAction.rawValue: Self.settingsWritten]) { $1 }
        #expect(model.bindings == expected, "Settings bindings differ from what the app applies")
        let rows: [(ShortcutAction, String)] = [
            (.newTab, "⌘T"),
            (.splitRight, "⌃B %"),
            (.closeWindow, "None"),
            (.toggleSidebar, "None"),
            (.find, "⇧⌘F5"),
            (.diffViewerScrollDown, "N"),
            // The app rejects these two entries and keeps the defaults.
            (.newWindow, "⇧⌘N"),
            (.quit, "⌘Q"),
        ]
        for (action, shown) in rows {
            let placeholder = model.formatPlaceholder(
                effective: model.effective(for: action),
                numbered: action.usesNumberedDigitMatching
            )
            #expect(placeholder == shown, "\(action.rawValue) row shows \(placeholder)")
        }
    }

    /// One recording that conflict detection must judge against the
    /// hand-written bindings rather than the defaults.
    struct ConflictCase: Sendable, CustomTestStringConvertible {
        let stroke: ShortcutStroke
        let conflict: ShortcutAction?
        let testDescription: String
    }

    @Test(arguments: [
        // newTab's default; the hand-written "cmd+t" moved newTab off it.
        ConflictCase(stroke: ShortcutStroke(key: "n", command: true), conflict: nil, testDescription: "cmd+n is free"),
        // closeWindow's default; the hand-written null unbound closeWindow.
        ConflictCase(stroke: ShortcutStroke(key: "w", command: true, control: true), conflict: nil, testDescription: "ctrl+cmd+w is free"),
        // The first stroke of splitRight's hand-written chord.
        ConflictCase(stroke: ShortcutStroke(key: "b", control: true), conflict: .splitRight, testDescription: "ctrl+b is taken"),
    ])
    func conflictDetectionUsesHandWrittenBindings(_ conflictCase: ConflictCase) async throws {
        // Arrange
        let action = ShortcutAction.openSettings
        let fileURL = try makeConfigFile(settingsWritten: [action.rawValue: Self.settingsWritten])
        let store = JSONConfigStore(fileURL: fileURL)
        let model = ShortcutListModel(jsonStore: store, catalog: SettingCatalog(), errorLog: SettingsErrorLog())
        model.startObserving()
        await spin(until: { model.bindings[action.rawValue] != nil })

        // Act
        await model.assign(stroke: conflictCase.stroke, to: action)

        // Assert
        let onDisk = try bindingsOnDisk(fileURL)
        #expect(model.conflictRejections[action.rawValue] == conflictCase.conflict)
        let expectedOnDisk = conflictCase.conflict == nil ? StoredShortcut(first: conflictCase.stroke) : Self.settingsWritten
        #expect(
            StoredShortcut.decodeFromJSON(onDisk[action.rawValue]) == expectedOnDisk,
            "openSettings on disk: \(String(describing: onDisk[action.rawValue]))"
        )
        try expectHandWrittenBindingsUnchanged(onDisk)
    }

    @Test func xButtonClearsAndRestoresAHandWrittenBinding() async throws {
        // WHY: the X button caches the effective stroke before clearing, and
        // restore writes that cache. Read as its default, the hand-written
        // "cmd+t" came back as ⌘N.

        // Arrange
        let action = ShortcutAction.newTab
        let syncAction = ShortcutAction.openSettings
        let fileURL = try makeConfigFile(settingsWritten: [syncAction.rawValue: Self.settingsWritten])
        let store = JSONConfigStore(fileURL: fileURL)
        let model = ShortcutListModel(jsonStore: store, catalog: SettingCatalog(), errorLog: SettingsErrorLog())
        model.startObserving()
        await spin(until: { model.bindings[syncAction.rawValue] != nil })
        let handWritten = try #require(Self.handWrittenAsApplied[action.rawValue])

        // Act
        await model.clearOrRestore(for: action)
        let clearedOnDisk = try bindingsOnDisk(fileURL)
        let canRestoreAfterClear = model.canRestore(for: action)
        await model.clearOrRestore(for: action)

        // Assert
        #expect(StoredShortcut.decodeFromJSON(clearedOnDisk[action.rawValue]) == .unbound)
        #expect(canRestoreAfterClear, "the X button lost its cached stroke after clearing")
        let restoredOnDisk = try bindingsOnDisk(fileURL)
        #expect(
            StoredShortcut.decodeFromJSON(restoredOnDisk[action.rawValue]) == handWritten,
            "restore wrote \(String(describing: restoredOnDisk[action.rawValue])), not the hand-written ⌘T"
        )
        await spin(until: { model.effective(for: action) == handWritten })
    }

    @Test func xButtonIsInertForAHandWrittenNull() async throws {
        // WHY: a hand-written null already unbinds the action. Read as the
        // default ⌃⌘W, the X button "cleared" it and replaced the null with an
        // object-form entry the user never asked for.

        // Arrange
        let action = ShortcutAction.closeWindow
        let syncAction = ShortcutAction.openSettings
        let fileURL = try makeConfigFile(settingsWritten: [syncAction.rawValue: Self.settingsWritten])
        let store = JSONConfigStore(fileURL: fileURL)
        let model = ShortcutListModel(jsonStore: store, catalog: SettingCatalog(), errorLog: SettingsErrorLog())
        model.startObserving()
        await spin(until: { model.bindings[syncAction.rawValue] != nil })

        // Act
        let effectiveBeforeClick = model.effective(for: action)
        let canRestoreBeforeClick = model.canRestore(for: action)
        await model.clearOrRestore(for: action)

        // Assert
        #expect(effectiveBeforeClick == .unbound, "closeWindow shows \(String(describing: effectiveBeforeClick))")
        #expect(!canRestoreBeforeClick)
        let onDisk = try bindingsOnDisk(fileURL)
        #expect(onDisk[action.rawValue] is NSNull, "closeWindow on disk: \(String(describing: onDisk[action.rawValue]))")
        try expectHandWrittenBindingsUnchanged(onDisk)
    }

    @Test func clearThenRestoreWithTheXButtonKeepsHandWrittenBindings() async throws {
        // WHY: the X/restore button's restore branch depends on the cached
        // stroke surviving the store's echo of the clear. This drives both
        // clicks through clearOrRestore after the first stream delivery, as the
        // Settings window does.

        // Arrange
        let action = ShortcutAction.toggleFullScreen
        let defaultShortcut = try #require(action.defaultShortcut)
        let otherAction = ShortcutAction.openSettings
        let fileURL = try makeConfigFile(settingsWritten: [otherAction.rawValue: Self.settingsWritten])
        let store = JSONConfigStore(fileURL: fileURL)
        let model = ShortcutListModel(jsonStore: store, catalog: SettingCatalog(), errorLog: SettingsErrorLog())
        model.startObserving()
        await spin(until: { model.bindings[otherAction.rawValue] != nil })

        // Act
        await model.clearOrRestore(for: action)
        let clearedOnDisk = try bindingsOnDisk(fileURL)
        let canRestoreAfterClear = model.canRestore(for: action)
        await model.clearOrRestore(for: action)

        // Assert
        #expect(StoredShortcut.decodeFromJSON(clearedOnDisk[action.rawValue]) == .unbound)
        try expectHandWrittenBindingsUnchanged(clearedOnDisk)
        #expect(canRestoreAfterClear, "the X button lost its cached stroke after clearing")
        let restoredOnDisk = try bindingsOnDisk(fileURL)
        #expect(StoredShortcut.decodeFromJSON(restoredOnDisk[action.rawValue]) == defaultShortcut)
        #expect(StoredShortcut.decodeFromJSON(restoredOnDisk[otherAction.rawValue]) == Self.settingsWritten)
        try expectHandWrittenBindingsUnchanged(restoredOnDisk)
        // The store's echo of the clear can reach the model after the restore
        // click; the row must settle on the restored stroke.
        await spin(until: { model.effective(for: action) == defaultShortcut })
    }

    @Test func resetDefaultsClearsHandWrittenBindingsToo() async throws {
        // WHY: Reset Defaults is the one edit meant to replace the whole
        // shortcuts.bindings object, including entries the package cannot decode.

        // Arrange
        let fileURL = try makeConfigFile()
        let store = JSONConfigStore(fileURL: fileURL)
        let model = ShortcutListModel(jsonStore: store, catalog: SettingCatalog(), errorLog: SettingsErrorLog())
        model.startObserving()

        // Act
        await model.resetAll()

        // Assert
        let onDisk = try bindingsOnDisk(fileURL)
        #expect(onDisk.isEmpty, "Reset Defaults left entries behind: \(onDisk)")
    }
}
