import CmuxFoundation
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// docs/cmux.schema.json is owned by this fork and embedded into the validator
/// behind `cmux config validate`, `cmux-settings set`, and the settings file
/// store's load-time log. A key the app reads but the schema lacks blocks the
/// user's config writes; a key the schema allows but the app ignores passes
/// validation and then silently does nothing. These tests hold the schema to
/// what the app actually reads.
@Suite
struct CmuxConfigSchemaDriftTests {
    private static let schemaURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "docs/cmux.schema.json")

    /// Top-level sections parsed by CmuxConfig (actions, commands, layouts), not
    /// by the settings file store, so they have no entries in
    /// `supportedSettingsJSONPaths`.
    private static let structuralSections: Set<String> = [
        "$schema", "schemaVersion", "actions", "ui", "commands", "vault",
        "newWorkspaceCommand", "surfaceTabBarButtons", "agentChat",
    ]
    private static let structuralPaths: Set<String> = ["workspaceGroups.byCwd"]

    private static func loadSchema() throws -> [String: Any] {
        let data = try Data(contentsOf: schemaURL)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Dotted paths of every settings leaf. A nested object with declared
    /// `properties` (e.g. terminal.agentHibernation) is walked; any other value
    /// (scalars, arrays, open dictionaries like workspaceColors.colors) is a leaf.
    /// Per-action binding schemas (`shortcuts.<action>` and
    /// `shortcuts.bindings.<action>`) are skipped; `shortcutActionIDsMatch`
    /// covers those ids.
    private static func settingsLeafPaths(in schema: [String: Any]) throws -> Set<String> {
        let sections = try #require(schema["properties"] as? [String: Any])
        let actionIDs = Set(KeyboardShortcutSettings.Action.allCases.map(\.rawValue))
        var paths: Set<String> = []
        func walk(_ path: String, _ node: [String: Any]) {
            let properties = (node["properties"] as? [String: Any] ?? [:])
                .filter { !actionIDs.contains($0.key) }
            guard !properties.isEmpty else {
                paths.insert(path)
                return
            }
            for (key, child) in properties {
                walk("\(path).\(key)", child as? [String: Any] ?? [:])
            }
        }
        for (key, node) in sections where !structuralSections.contains(key) {
            walk(key, node as? [String: Any] ?? [:])
        }
        return paths.subtracting(structuralPaths)
    }

    @Test("the app's default cmux.json template passes semantic validation")
    func defaultTemplateValidates() throws {
        // Arrange: the same sections the app writes, round-tripped through JSON
        // so numbers and booleans have the types a file on disk produces.
        let template = CmuxSettingsFileStore.defaultTemplateSections()
            .reduce(into: [String: Any]()) { merged, section in
                merged.merge(section) { _, new in new }
            }
        let data = try JSONSerialization.data(withJSONObject: template)

        // Act
        let issues = try CmuxConfigSemanticValidator(scope: .global).validate(jsonData: data)

        // Assert
        #expect(issues.isEmpty, "template values the schema rejects: \(issues.map { "\($0.path): \($0.message)" })")
    }

    @Test("schema settings paths equal the paths the settings file store reads")
    func settingsPathsMatchTheFileStore() throws {
        // Arrange
        let schemaPaths = try Self.settingsLeafPaths(in: Self.loadSchema())
        let appPaths = CmuxSettingsFileStore.supportedSettingsJSONPaths

        // Act
        let missingFromSchema = appPaths.subtracting(schemaPaths).sorted()
        let ignoredByApp = schemaPaths.subtracting(appPaths).sorted()

        // Assert
        #expect(missingFromSchema.isEmpty, "the app reads these but docs/cmux.schema.json rejects them: \(missingFromSchema)")
        #expect(ignoredByApp.isEmpty, "docs/cmux.schema.json accepts these but the app never reads them: \(ignoredByApp)")
    }

    @Test("every template path is a supported settings path")
    func templatePathsAreSupported() throws {
        // Arrange
        let template = CmuxSettingsFileStore.defaultTemplateSections()
            .reduce(into: [String: Any]()) { merged, section in
                merged.merge(section) { _, new in new }
            }
        let schemaPaths = try Self.settingsLeafPaths(in: Self.loadSchema())

        // Act: a template value is a leaf unless the schema walks into it.
        var templatePaths: Set<String> = []
        func walk(_ path: String, _ value: Any) {
            guard let object = value as? [String: Any], !schemaPaths.contains(path) else {
                templatePaths.insert(path)
                return
            }
            for (key, child) in object {
                walk("\(path).\(key)", child)
            }
        }
        for (key, value) in template {
            walk(key, value)
        }

        // Assert
        let unsupported = templatePaths.subtracting(CmuxSettingsFileStore.supportedSettingsJSONPaths).sorted()
        #expect(unsupported.isEmpty, "the template writes these but supportedSettingsJSONPaths lacks them: \(unsupported)")
    }

    @Test("every cmux.json-backed catalog key is a path the schema declares")
    func jsonCatalogKeysAreDeclared() throws {
        // Arrange: keys the app reads and writes through JSONConfigStore.
        let schemaPaths = try Self.settingsLeafPaths(in: Self.loadSchema())
        let jsonKeyIDs = Set(SettingCatalog().all.filter { $0.kind == .jsonConfig }.map(\.id))

        // Act
        let undeclared = jsonKeyIDs.subtracting(schemaPaths).sorted()

        // Assert
        #expect(!jsonKeyIDs.isEmpty)
        #expect(undeclared.isEmpty, "the app stores these in cmux.json but docs/cmux.schema.json rejects them: \(undeclared)")
    }

    @Test("customSidebars.renderer accepts every renderer mode and nothing else")
    func customSidebarRendererModesMatch() throws {
        // Arrange
        let validator = CmuxConfigSemanticValidator(scope: .global)

        // Act
        let modeIssues = CustomSidebarRendererMode.allCases.flatMap {
            validator.validate(jsonObject: ["customSidebars": ["renderer": $0.rawValue]])
        }
        let unknownModeIssues = validator.validate(jsonObject: ["customSidebars": ["renderer": "sandboxed"]])

        // Assert
        #expect(modeIssues.isEmpty, "\(modeIssues)")
        #expect(unknownModeIssues.contains { $0.path == "$.customSidebars.renderer" })
    }

    @Test("shortcut binding ids in the schema equal the app's shortcut actions")
    func shortcutActionIDsMatch() throws {
        // Arrange
        let schema = try Self.loadSchema()
        let properties = try #require(schema["properties"] as? [String: Any])
        let shortcuts = try #require(properties["shortcuts"] as? [String: Any])
        let shortcutProperties = try #require(shortcuts["properties"] as? [String: Any])
        let bindings = try #require(shortcutProperties["bindings"] as? [String: Any])
        let propertyNames = try #require(bindings["propertyNames"] as? [String: Any])
        let definitions = try #require(schema["$defs"] as? [String: Any])
        let actionIDDefinition = try #require(definitions["shortcutActionId"] as? [String: Any])
        let schemaIDs = Set(try #require(actionIDDefinition["enum"] as? [String]))
        let appIDs = Set(KeyboardShortcutSettings.Action.allCases.map(\.rawValue))

        // Act
        let missingFromSchema = appIDs.subtracting(schemaIDs).sorted()
        let unknownToApp = schemaIDs.subtracting(appIDs).sorted()

        // Assert
        #expect(propertyNames["$ref"] as? String == "#/$defs/shortcutActionId")
        #expect(missingFromSchema.isEmpty, "shortcut actions the schema rejects: \(missingFromSchema)")
        #expect(unknownToApp.isEmpty, "shortcut ids the schema accepts but the app has no action for: \(unknownToApp)")
    }
}
