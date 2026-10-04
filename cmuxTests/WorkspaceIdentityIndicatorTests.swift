import Combine
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The workspace color that the title bar dot, the focused-pane outline and the
/// jump banner show: which color wins, and how it follows selection and edits.
@MainActor
@Suite("Workspace identity color", .serialized)
struct WorkspaceIdentityColorTests {
    private func makeTabManager() -> TabManager {
        let suiteName = "cmux.workspace-identity-tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return TabManager(
            autoWelcomeIfNeeded: false,
            settings: UserDefaultsSettingsClient(defaults: defaults),
            closeTabWarningDefaults: defaults
        )
    }

    @Test(
        "a group anchor's valid group color wins; otherwise the workspace's own color, normalized",
        arguments: [
            ("#c0392b", nil, "#C0392B"),
            ("#C0392B", "#1565C0", "#1565C0"),
            ("#C0392B", "not-a-color", "#C0392B"),
            (nil, "1565c0", "#1565C0"),
            ("   ", nil, nil),
            (nil, nil, nil),
        ] as [(String?, String?, String?)]
    )
    func indicatorColorResolution(workspaceColorHex: String?, anchorGroupColorHex: String?, expected: String?) {
        let resolved = TabManager.workspaceIndicatorColorHex(
            workspaceColorHex: workspaceColorHex,
            anchorGroupColorHex: anchorGroupColorHex
        )

        #expect(resolved == expected)
    }

    @Test("a group's anchor shows the group's color while its members keep their own")
    func groupAnchorUsesGroupColor() throws {
        let manager = makeTabManager()
        let member = manager.addWorkspace(title: "Member", select: true, autoWelcomeIfNeeded: false)
        member.setCustomColor("#196F3D")
        let groupId = try #require(manager.createWorkspaceGroup(name: "Project", childWorkspaceIds: [member.id]))
        let anchorId = try #require(manager.workspaceGroups.first { $0.id == groupId }?.anchorWorkspaceId)
        let anchor = try #require(manager.workspacesById[anchorId])

        let anchorBeforeGroupColor = manager.resolvedWorkspaceIndicatorColorHex(for: anchor)
        manager.setWorkspaceGroupColor(groupId: groupId, hex: "#1565C0")
        let anchorAfterGroupColor = manager.resolvedWorkspaceIndicatorColorHex(for: anchor)
        let memberAfterGroupColor = manager.resolvedWorkspaceIndicatorColorHex(for: member)

        #expect(anchorBeforeGroupColor == nil)
        #expect(anchorAfterGroupColor == "#1565C0")
        #expect(memberAfterGroupColor == "#196F3D")
    }

    @Test("the selected-workspace color stream follows selection and ignores edits to unselected workspaces")
    func selectedColorPublisherFollowsSelection() {
        let manager = makeTabManager()
        let first = manager.addWorkspace(title: "First", select: true, autoWelcomeIfNeeded: false)
        let second = manager.addWorkspace(title: "Second", select: false, autoWelcomeIfNeeded: false)
        var received: [String?] = []
        let subscription = manager.selectedWorkspaceIndicatorColorHexPublisher.sink { received.append($0) }
        defer { subscription.cancel() }

        first.setCustomColor("#C0392B")
        manager.selectTab(second)
        first.setCustomColor("#1565C0")
        second.setCustomColor("#196F3D")
        manager.selectTab(first)
        second.setCustomColor(nil)

        #expect(received == [nil, "#C0392B", nil, "#196F3D", "#1565C0"])
    }
}

@Suite("Workspace identity settings file", .serialized)
struct WorkspaceIdentitySettingsFileTests {
    private let settingsFileBackupsDefaultsKey = "cmux.settingsFile.backups.v1"
    private let importedManagedDefaultsKey = "cmux.settingsFile.importedManagedDefaults.v1"
    private let titlebarKey = WorkspaceColorsCatalogSection().titlebarIndicator.userDefaultsKey
    private let paneBorderKey = WorkspaceColorsCatalogSection().paneBorder.userDefaultsKey
    private let jumpNameKey = NotificationsCatalogSection().jumpShowsWorkspaceName.userDefaultsKey

    @Test("the three toggles default to on")
    func togglesDefaultOn() {
        let catalog = SettingCatalog()

        #expect(catalog.workspaceColors.titlebarIndicator.defaultValue)
        #expect(catalog.workspaceColors.paneBorder.defaultValue)
        #expect(catalog.notifications.jumpShowsWorkspaceName.defaultValue)
    }

    /// `workspaceColors` parsing returns early once it handles `colors`, so the
    /// toggles must be read before that or a palette in the same file drops them.
    @Test("cmux.json turns the toggles off even next to a workspace color palette")
    func settingsFileAppliesToggles() throws {
        try withScratchSettingsFile(
            """
            {
              "workspaceColors": {
                "colors": { "Red": "#C0392B" },
                "titlebarIndicator": false,
                "paneBorder": false
              },
              "notifications": { "jumpShowsWorkspaceName": false }
            }
            """
        ) { defaults in
            #expect(defaults.object(forKey: titlebarKey) as? Bool == false)
            #expect(defaults.object(forKey: paneBorderKey) as? Bool == false)
            #expect(defaults.object(forKey: jumpNameKey) as? Bool == false)
        }
    }

    @Test("non-boolean values are rejected and leave the toggles at their defaults")
    func settingsFileRejectsNonBooleans() throws {
        try withScratchSettingsFile(
            """
            {
              "workspaceColors": { "titlebarIndicator": "no", "paneBorder": 0.5 },
              "notifications": { "jumpShowsWorkspaceName": "off" }
            }
            """
        ) { defaults in
            let client = UserDefaultsSettingsClient(defaults: defaults)
            #expect(client.value(for: SettingCatalog().workspaceColors.titlebarIndicator))
            #expect(client.value(for: SettingCatalog().workspaceColors.paneBorder))
            #expect(client.value(for: SettingCatalog().notifications.jumpShowsWorkspaceName))
        }
    }

    private func withScratchSettingsFile(_ contents: String, _ check: (UserDefaults) throws -> Void) throws {
        let defaults = UserDefaults.standard
        let keys = [
            titlebarKey,
            paneBorderKey,
            jumpNameKey,
            WorkspaceTabColorSettings.paletteKey,
            settingsFileBackupsDefaultsKey,
            importedManagedDefaultsKey,
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        keys.forEach(defaults.removeObject(forKey:))
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-workspace-identity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directoryURL) }
        let settingsFileURL = directoryURL.appendingPathComponent("cmux.json", isDirectory: false)
        try contents.write(to: settingsFileURL, atomically: true, encoding: .utf8)

        _ = KeyboardShortcutSettingsFileStore(
            primaryPath: settingsFileURL.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )

        try check(defaults)
    }
}
