import Foundation
import Testing
@testable import CmuxSettings

/// Per-entry reads and writes of a dictionary-valued JSON key whose object
/// also holds entries the element type cannot decode. `shortcuts.bindings` is
/// the real case: users hand-write `"cmd+t"`, `["ctrl+b", "%"]` and `null`
/// bindings next to the object form Settings writes, and can also write
/// bindings the app rejects (an unknown key name, a number, a bare first
/// stroke for an action that needs a modifier).
@Suite("JSONConfigStore dictionary entries")
struct JSONConfigStoreDictionaryEntryTests {
    private static let settingsWritten = StoredShortcut(first: ShortcutStroke(key: ",", command: true))
    private static let recorded = StoredShortcut(
        first: ShortcutStroke(key: "j", command: true, shift: true, option: true, control: true)
    )

    /// What the hand-written and object-form entries of ``mixedConfigJSON`` decode to.
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

    private func makeStore(contents: String? = nil) throws -> (JSONConfigStore, URL, SettingCatalog) {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-settings-entries-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        let fileURL = tempDir.appendingPathComponent("cmux.json", isDirectory: false)
        if let contents { try Data(contents.utf8).write(to: fileURL) }
        return (JSONConfigStore(fileURL: fileURL), fileURL, SettingCatalog())
    }

    private func rootOnDisk(_ fileURL: URL) throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: fileURL)) as? [String: Any])
    }

    private func bindingsOnDisk(_ fileURL: URL) throws -> [String: Any] {
        let shortcuts = try #require(try rootOnDisk(fileURL)["shortcuts"] as? [String: Any])
        return try #require(shortcuts["bindings"] as? [String: Any], "shortcuts.bindings is missing")
    }

    @Test func mergeRewritesOnlyTheNamedEntries() async throws {
        // Arrange
        let (store, fileURL, catalog) = try makeStore(contents: Self.mixedConfigJSON)
        let before = try bindingsOnDisk(fileURL)

        // Act: add one entry and replace one hand-written entry.
        try await store.merge(
            ["toggleFullScreen": Self.recorded, "newTab": .unbound],
            into: catalog.shortcuts.bindings
        )

        // Assert
        let after = try bindingsOnDisk(fileURL)
        #expect(StoredShortcut.decodeFromJSON(after["toggleFullScreen"]) == Self.recorded)
        #expect(StoredShortcut.decodeFromJSON(after["newTab"]) == .unbound)
        let untouched = ["splitRight", "closeWindow", "newWindow", "quit", "toggleSidebar", "openSettings"]
        #expect(Set(after.keys) == Set(untouched + ["toggleFullScreen", "newTab"]))
        for key in untouched {
            #expect(
                (after[key] as? NSObject)?.isEqual(before[key]) == true,
                "\(key) changed from \(String(describing: before[key])) to \(String(describing: after[key]))"
            )
        }
        #expect((try rootOnDisk(fileURL)["app"] as? [String: Any])?["appearance"] as? String == "dark")
    }

    @Test func mergeKeepsADottedEntryKeyAsOneEntry() async throws {
        // Arrange: no file yet, so merge must also create the file and object.
        let (store, fileURL, catalog) = try makeStore()

        // Act
        try await store.merge(["a.b": Self.recorded], into: catalog.shortcuts.bindings)

        // Assert
        let onDisk = try bindingsOnDisk(fileURL)
        #expect(Array(onDisk.keys) == ["a.b"], "dotted entry key was split into nested objects: \(onDisk)")
        #expect(StoredShortcut.decodeFromJSON(onDisk["a.b"]) == Self.recorded)
        #expect(await store.value(forDecodableEntriesOf: catalog.shortcuts.bindings) == ["a.b": Self.recorded])
    }

    @Test func decodableEntriesSkipEntriesTheElementCannotDecode() async throws {
        // Arrange
        let (store, _, catalog) = try makeStore(contents: Self.mixedConfigJSON)

        // Act
        let entries = await store.value(forDecodableEntriesOf: catalog.shortcuts.bindings)

        // Assert
        #expect(entries == Self.decodableEntries)
    }

    @Test(arguments: [
        nil,
        #"{"app": {"appearance": "dark"}}"#,
        #"{"shortcuts": {"bindings": "cmd+t"}}"#,
        #"{"shortcuts": {"bindings": ["cmd+t"]}}"#,
    ])
    func decodableEntriesFallBackToTheDefaultWithoutAnObject(_ contents: String?) async throws {
        // Arrange
        let (store, _, catalog) = try makeStore(contents: contents)

        // Act
        let entries = await store.value(forDecodableEntriesOf: catalog.shortcuts.bindings)

        // Assert
        #expect(entries == catalog.shortcuts.bindings.defaultValue)
    }

    @Test func decodableEntriesStreamFollowsExternalEdits() async throws {
        // Arrange
        let (store, fileURL, catalog) = try makeStore(contents: Self.mixedConfigJSON)
        let key = catalog.shortcuts.bindings
        let edited = Self.mixedConfigJSON.replacingOccurrences(
            of: #""closeWindow": null,"#,
            with: #""closeWindow": null, "toggleFullScreen": {"first": {"key": "j", "command": true, "shift": true, "option": true, "control": true}},"#
        )
        try #require(edited != Self.mixedConfigJSON, "fixture edit did not apply")
        let (ready, readyContinuation) = AsyncStream<Void>.makeStream()
        let observed = Task<[[String: StoredShortcut]], Never> {
            var collected: [[String: StoredShortcut]] = []
            for await entries in store.values(forDecodableEntriesOf: key) {
                collected.append(entries)
                if collected.count == 1 { readyContinuation.yield() }
                if entries["toggleFullScreen"] != nil { break }
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
}
