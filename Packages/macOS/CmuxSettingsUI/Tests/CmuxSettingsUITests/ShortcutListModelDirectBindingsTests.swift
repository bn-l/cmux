import CmuxSettings
import Foundation
import Testing

@testable import CmuxSettingsUI

/// Bindings written directly in cmux.json's `shortcuts` object
/// (`"shortcuts": {"newTab": "cmd+y"}`). The app applies them over
/// `shortcuts.bindings`. Settings must show them, and an edit in Settings must
/// land where the app reads it; otherwise the direct entry overrides the edit
/// and the shortcut the user just recorded does nothing.
@MainActor
@Suite struct ShortcutListModelDirectBindingsTests {
    private static let configJSON = #"""
    {
      "app": {"appearance": "dark"},
      "shortcuts": {
        "showModifierHoldHints": false,
        "when": {"newTab": "terminalFocus"},
        "newTab": "cmd+y",
        "find": {"first": {"key": "e", "command": true, "option": true}},
        "selectWorkspaceByNumber": "ctrl+5",
        "globalSearch": "shift+g",
        "bindings": {
          "newTab": "cmd+t",
          "splitRight": ["ctrl+b", "%"],
          "openSettings": {"first": {"key": "u", "command": true, "shift": true, "option": true, "control": true}}
        }
      }
    }
    """#

    private static let settingsWritten = StoredShortcut(
        first: ShortcutStroke(key: "u", command: true, shift: true, option: true, control: true)
    )

    private func makeModel() throws -> (ShortcutListModel, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("shortcut-direct-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json")
        try Data(Self.configJSON.utf8).write(to: fileURL)
        let model = ShortcutListModel(
            jsonStore: JSONConfigStore(fileURL: fileURL),
            catalog: SettingCatalog(),
            errorLog: SettingsErrorLog()
        )
        return (model, fileURL)
    }

    /// Starts the model and waits for the first read of the file.
    private func startObserving(_ model: ShortcutListModel) async {
        model.startObserving()
        await spin(until: { model.bindings[ShortcutAction.openSettings.rawValue] != nil })
    }

    private func spin(until condition: () -> Bool) async {
        var spins = 0
        while !condition(), spins < 100_000 {
            await Task.yield()
            spins += 1
        }
        #expect(condition(), "spin(until:) timed out after 100 000 yields")
    }

    private func shortcutsOnDisk(_ fileURL: URL) throws -> [String: Any] {
        let root = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any],
            "cmux.json is not a JSON object"
        )
        return try #require(root["shortcuts"] as? [String: Any], "cmux.json lost its shortcuts object")
    }

    @Test func modelShowsDirectBindingsAsTheAppAppliesThem() async throws {
        // Arrange
        let (model, _) = try makeModel()

        // Act
        await startObserving(model)

        // Assert
        #expect(model.bindings == [
            // The direct entry wins over shortcuts.bindings.newTab ("cmd+t").
            "newTab": StoredShortcut(first: ShortcutStroke(key: "y", command: true)),
            // Object form with the unset flags left out, as people write it by hand.
            "find": StoredShortcut(first: ShortcutStroke(key: "e", command: true, option: true)),
            // A numbered action stores its digit as the "1" placeholder.
            "selectWorkspaceByNumber": StoredShortcut(first: ShortcutStroke(key: "1", control: true)),
            "splitRight": StoredShortcut(first: ShortcutStroke(key: "b", control: true), second: ShortcutStroke(key: "%")),
            "openSettings": Self.settingsWritten,
            // "shift+g" cannot be a system-wide hotkey, so globalSearch keeps its default.
        ])
        let rows: [(ShortcutAction, String)] = [(.newTab, "⌘Y"), (.find, "⌥⌘E"), (.globalSearch, "⌥⌘F")]
        for (action, shown) in rows {
            let placeholder = model.formatPlaceholder(effective: model.effective(for: action), numbered: false)
            #expect(placeholder == shown, "\(action.rawValue) row shows \(placeholder)")
        }
    }

    @Test func recordingADirectlyBoundActionReplacesTheDirectEntry() async throws {
        // Arrange
        let (model, fileURL) = try makeModel()
        await startObserving(model)
        let recorded = ShortcutStroke(key: "j", command: true, shift: true, option: true, control: true)

        // Act
        await model.assign(stroke: recorded, to: .newTab)

        // Assert
        let shortcuts = try shortcutsOnDisk(fileURL)
        #expect(StoredShortcut.decodeFromJSON(shortcuts["newTab"]) == StoredShortcut(first: recorded))
        let bindings = try #require(shortcuts["bindings"] as? [String: Any])
        #expect(bindings["newTab"] as? String == "cmd+t", "the overridden bindings entry must stay as written")
        // The model re-reads the file and must still show the recorded stroke.
        await spin(until: { model.effective(for: .newTab) == StoredShortcut(first: recorded) })
        #expect(model.bindings["newTab"] == StoredShortcut(first: recorded))
    }

    @Test func clearingADirectlyBoundActionUnbindsIt() async throws {
        // Arrange
        let (model, fileURL) = try makeModel()
        await startObserving(model)

        // Act: the X button.
        await model.clearOrRestore(for: .find)

        // Assert
        let shortcuts = try shortcutsOnDisk(fileURL)
        #expect(StoredShortcut.decodeFromJSON(shortcuts["find"]) == .unbound)
        #expect((shortcuts["bindings"] as? [String: Any])?["find"] == nil)
        await spin(until: { model.effective(for: .find) == .unbound })
        #expect(model.canRestore(for: .find))
    }

    @Test func resetDefaultsClearsDirectBindingsToo() async throws {
        // Arrange
        let (model, fileURL) = try makeModel()
        await startObserving(model)

        // Act
        await model.resetAll()

        // Assert: no binding is left in either place, the other shortcut
        // settings stay, and every row is back on its default.
        let shortcuts = try shortcutsOnDisk(fileURL)
        #expect(Set(shortcuts.keys) == ["showModifierHoldHints", "when", "bindings"])
        #expect((shortcuts["bindings"] as? [String: Any])?.isEmpty == true)
        await spin(until: { model.bindings.isEmpty })
        for action in [ShortcutAction.newTab, .find, .selectWorkspaceByNumber, .splitRight, .openSettings] {
            #expect(model.effective(for: action) == action.defaultShortcut, "\(action.rawValue)")
        }
    }
}
