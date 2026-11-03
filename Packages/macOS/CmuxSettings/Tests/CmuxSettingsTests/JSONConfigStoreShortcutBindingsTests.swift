import Foundation
import Testing
@testable import CmuxSettings

/// Reads and writes of keyboard shortcut bindings through ``JSONConfigStore``.
///
/// cmux.json holds bindings in `shortcuts.bindings` and directly in
/// `shortcuts`, where they override `bindings`. Users hand-write `"cmd+t"`,
/// `["ctrl+b", "%"]` and `null` next to the object form Settings writes, and
/// can write bindings the app rejects (an unknown key name, a number, a bare
/// first stroke for an action that needs a modifier). Settings must show the
/// binding the app applies, and a write must land where the app reads it.
@Suite("JSONConfigStore shortcut bindings")
struct JSONConfigStoreShortcutBindingsTests {
    private static let settingsWritten = StoredShortcut(first: ShortcutStroke(key: ",", command: true))
    private static let recorded = StoredShortcut(
        first: ShortcutStroke(key: "j", command: true, shift: true, option: true, control: true)
    )

    /// What the valid entries of ``mixedConfigJSON`` decode to.
    private static let decodableEntries: [String: StoredShortcut] = [
        "newTab": StoredShortcut(first: ShortcutStroke(key: "t", command: true)),
        "splitRight": StoredShortcut(first: ShortcutStroke(key: "b", control: true), second: ShortcutStroke(key: "%")),
        "closeWindow": .unbound,
        "openSettings": settingsWritten,
    ]

    /// A cmux.json whose `shortcuts.bindings` mixes hand-written forms, one
    /// object-form entry and three entries the app rejects, next to an
    /// unrelated setting.
    private static let mixedConfigJSON = #"""
    {
      "app": {"appearance": "dark"},
      "shortcuts": {
        "bindings": {
          "newTab": "cmd+t",
          "splitRight": ["ctrl+b", "%"],
          "closeWindow": null,
          "newWindow": "cmd+bogus",
          "quit": 42,
          "toggleSidebar": "n",
          "openSettings": {"first": {"key": ",", "command": true, "shift": false, "option": false, "control": false}}
        }
      }
    }
    """#

    /// A cmux.json with bindings in both places, plus the other `shortcuts`
    /// settings and a key that is not an action id.
    private static let directEntriesJSON = #"""
    {
      "shortcuts": {
        "showModifierHoldHints": false,
        "when": {"newTab": "terminalFocus"},
        "notAnAction": "cmd+9",
        "newTab": "cmd+y",
        "closeWindow": null,
        "find": {"first": {"key": "f", "command": true}},
        "toggleSidebar": "cmd+bogus",
        "bindings": {
          "newTab": "cmd+t",
          "toggleSidebar": "cmd+b",
          "splitRight": ["ctrl+b", "%"]
        }
      }
    }
    """#

    private func makeStore(contents: String? = nil) throws -> (JSONConfigStore, URL) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-shortcuts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        if let contents { try Data(contents.utf8).write(to: fileURL) }
        return (JSONConfigStore(fileURL: fileURL), fileURL)
    }

    private func rootOnDisk(_ fileURL: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
    }

    private func shortcutsOnDisk(_ fileURL: URL) throws -> [String: Any] {
        try #require(try rootOnDisk(fileURL)["shortcuts"] as? [String: Any], "shortcuts is missing")
    }

    private func bindingsOnDisk(_ fileURL: URL) throws -> [String: Any] {
        try #require(try shortcutsOnDisk(fileURL)["bindings"] as? [String: Any], "shortcuts.bindings is missing")
    }

    /// Asserts each key of `keys` holds the same JSON value in `after` as in `before`.
    private func expectUnchanged(_ keys: [String], before: [String: Any], after: [String: Any]) {
        for key in keys {
            #expect(
                (after[key] as? NSObject)?.isEqual(before[key]) == true,
                "\(key) changed from \(String(describing: before[key])) to \(String(describing: after[key]))"
            )
        }
    }

    // MARK: - Reads

    @Test func readSkipsEntriesTheAppRejects() async throws {
        // Arrange
        let (store, _) = try makeStore(contents: Self.mixedConfigJSON)

        // Act
        let bindings = await store.shortcutBindings()

        // Assert
        #expect(bindings == Self.decodableEntries)
    }

    @Test(arguments: [
        nil,
        #"{"app": {"appearance": "dark"}}"#,
        #"{"shortcuts": "cmd+t"}"#,
        #"{"shortcuts": {"bindings": "cmd+t"}}"#,
        #"{"shortcuts": {"bindings": ["cmd+t"]}}"#,
        #"{"shortcuts": {"showModifierHoldHints": true, "when": {"newTab": "terminalFocus"}}}"#,
    ])
    func readIsEmptyWithoutBindings(_ contents: String?) async throws {
        // Arrange
        let (store, _) = try makeStore(contents: contents)

        // Act
        let bindings = await store.shortcutBindings()

        // Assert
        #expect(bindings.isEmpty)
    }

    @Test func directEntriesOverrideBindingsEntries() async throws {
        // Arrange
        let (store, _) = try makeStore(contents: Self.directEntriesJSON)

        // Act
        let bindings = await store.shortcutBindings()

        // Assert: the direct entry wins for newTab; an invalid direct entry
        // still overrides, so toggleSidebar is on its default like in the app.
        #expect(bindings == [
            "newTab": StoredShortcut(first: ShortcutStroke(key: "y", command: true)),
            "closeWindow": .unbound,
            "find": StoredShortcut(first: ShortcutStroke(key: "f", command: true)),
            "splitRight": StoredShortcut(first: ShortcutStroke(key: "b", control: true), second: ShortcutStroke(key: "%")),
        ])
    }

    @Test func streamFollowsExternalEdits() async throws {
        // Arrange
        let (store, fileURL) = try makeStore(contents: Self.mixedConfigJSON)
        let edited = Self.mixedConfigJSON.replacingOccurrences(
            of: #""closeWindow": null,"#,
            with: #""closeWindow": null, "toggleFullScreen": {"first": {"key": "j", "command": true, "shift": true, "option": true, "control": true}},"#
        )
        try #require(edited != Self.mixedConfigJSON, "fixture edit did not apply")
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let observed = Task<[[String: StoredShortcut]], Never> {
            var collected: [[String: StoredShortcut]] = []
            for await bindings in store.shortcutBindingValues() {
                collected.append(bindings)
                if collected.count == 1 { readyContinuation.yield() }
                if bindings["toggleFullScreen"] != nil { break }
            }
            return collected
        }
        await withTimeout(seconds: 8) {
            var iterator = ready.makeAsyncIterator()
            _ = await iterator.next()
        }

        // Act
        let writer = retouchingWriter(payload: edited, fileURL: fileURL)
        let collected = await observedValues(observed)
        writer.cancel()

        // Assert
        #expect(collected.first == Self.decodableEntries)
        #expect(collected.last == Self.decodableEntries.merging(["toggleFullScreen": Self.recorded]) { $1 })
    }

    // MARK: - Writes

    @Test func writeRewritesOnlyTheNamedEntry() async throws {
        // Arrange
        let (store, fileURL) = try makeStore(contents: Self.mixedConfigJSON)
        let before = try bindingsOnDisk(fileURL)

        // Act: add one entry and replace one hand-written entry.
        try await store.setShortcutBinding(Self.recorded, for: .toggleFullScreen)
        try await store.setShortcutBinding(.unbound, for: .newTab)

        // Assert
        let after = try bindingsOnDisk(fileURL)
        #expect(StoredShortcut.decodeFromJSON(after["toggleFullScreen"]) == Self.recorded)
        #expect(StoredShortcut.decodeFromJSON(after["newTab"]) == .unbound)
        let untouched = ["splitRight", "closeWindow", "newWindow", "quit", "toggleSidebar", "openSettings"]
        #expect(Set(after.keys) == Set(untouched + ["toggleFullScreen", "newTab"]))
        expectUnchanged(untouched, before: before, after: after)
        #expect((try rootOnDisk(fileURL)["app"] as? [String: Any])?["appearance"] as? String == "dark")
        #expect(await store.shortcutBindings()["toggleFullScreen"] == Self.recorded)
    }

    @Test func writeCreatesTheFileAndObject() async throws {
        // Arrange: no file yet.
        let (store, fileURL) = try makeStore()

        // Act
        try await store.setShortcutBinding(Self.recorded, for: .newTab)

        // Assert
        let onDisk = try bindingsOnDisk(fileURL)
        #expect(Array(onDisk.keys) == ["newTab"])
        #expect(StoredShortcut.decodeFromJSON(onDisk["newTab"]) == Self.recorded)
        #expect(await store.shortcutBindings() == ["newTab": Self.recorded])
    }

    @Test func writeReplacesTheDirectEntryTheAppApplies() async throws {
        // Arrange
        let (store, fileURL) = try makeStore(contents: Self.directEntriesJSON)
        let beforeShortcuts = try shortcutsOnDisk(fileURL)
        let beforeBindings = try bindingsOnDisk(fileURL)

        // Act: newTab and closeWindow are bound directly; splitRight only in bindings.
        try await store.setShortcutBinding(Self.recorded, for: .newTab)
        try await store.setShortcutBinding(Self.settingsWritten, for: .closeWindow)
        try await store.setShortcutBinding(.unbound, for: .splitRight)

        // Assert: each write lands where the app reads it, so it takes effect.
        let shortcuts = try shortcutsOnDisk(fileURL)
        let bindings = try bindingsOnDisk(fileURL)
        #expect(StoredShortcut.decodeFromJSON(shortcuts["newTab"]) == Self.recorded)
        #expect(StoredShortcut.decodeFromJSON(shortcuts["closeWindow"]) == Self.settingsWritten)
        #expect(StoredShortcut.decodeFromJSON(bindings["splitRight"]) == .unbound)
        #expect(shortcuts["splitRight"] == nil, "a binding only in shortcuts.bindings must stay there")
        expectUnchanged(
            ["showModifierHoldHints", "when", "notAnAction", "find", "toggleSidebar"],
            before: beforeShortcuts,
            after: shortcuts
        )
        expectUnchanged(["newTab", "toggleSidebar"], before: beforeBindings, after: bindings)
        let read = await store.shortcutBindings()
        #expect(read["newTab"] == Self.recorded)
        #expect(read["closeWindow"] == Self.settingsWritten)
        #expect(read["splitRight"] == .unbound)
    }

    @Test func resetRemovesBindingsFromBothPlaces() async throws {
        // Arrange
        let (store, fileURL) = try makeStore(contents: Self.directEntriesJSON)
        let before = try shortcutsOnDisk(fileURL)

        // Act
        try await store.resetShortcutBindings()

        // Assert
        let after = try shortcutsOnDisk(fileURL)
        #expect(Set(after.keys) == ["showModifierHoldHints", "when", "notAnAction", "bindings"])
        #expect(try bindingsOnDisk(fileURL).isEmpty)
        expectUnchanged(["showModifierHoldHints", "when", "notAnAction"], before: before, after: after)
        #expect(await store.shortcutBindings().isEmpty)
    }
}
