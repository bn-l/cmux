import CmuxControlSocket
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Focus Last (upstream manaflow-ai/cmux#14700 + #14760): the app shortcut,
/// the History menu item and `workspace.last` (`cmux last-window`, tmux `-`)
/// all toggle between the two most recent positions instead of walking
/// further back through history.
@MainActor
@Suite(.serialized)
struct FocusLastToggleTests {
    @Test func focusLastTogglesBetweenTheTwoMostRecentWorkspaces() throws {
        // Arrange
        let (manager, cleanup) = try makeManager()
        defer { cleanup() }
        let first = try #require(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: true)
        let third = manager.addWorkspace(select: true)
        FocusSurfaceBroadcaster.shared.flush()
        try #require(manager.selectedTabId == third.id)

        // Act / Assert: toggles third <-> second, never reaches first.
        for expected in [second.id, third.id, second.id, third.id] {
            #expect(manager.navigateToLastFocused())
            FocusSurfaceBroadcaster.shared.flush()
            #expect(manager.selectedTabId == expected)
        }
        #expect(manager.selectedTabId != first.id)
    }

    @Test func focusLastHasNowhereToGoInAFreshManager() throws {
        let (manager, cleanup) = try makeManager()
        defer { cleanup() }
        let only = try #require(manager.selectedWorkspace)

        #expect(!manager.navigateToLastFocused())
        #expect(manager.selectedTabId == only.id)
    }

    @Test func closingTheToggleTargetClearsIt() throws {
        // Arrange
        let (manager, cleanup) = try makeManager()
        defer { cleanup() }
        _ = try #require(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: true)
        let third = manager.addWorkspace(select: true)
        FocusSurfaceBroadcaster.shared.flush()

        // Act
        manager.closeWorkspace(second)
        FocusSurfaceBroadcaster.shared.flush()

        // Assert: the closed workspace is never a target.
        _ = manager.navigateToLastFocused()
        FocusSurfaceBroadcaster.shared.flush()
        #expect(manager.selectedTabId != second.id)
        #expect(manager.tabs.contains { $0.id == third.id })
    }

    @Test func workspaceLastSocketCommandTogglesLikeFocusLast() throws {
        // Arrange
        let (manager, cleanup) = try makeManager()
        defer { cleanup() }
        let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
        TerminalController.shared.setActiveTabManager(manager)
        defer { TerminalController.shared.setActiveTabManager(previousManager) }
        _ = try #require(manager.selectedWorkspace)
        let second = manager.addWorkspace(select: true)
        let third = manager.addWorkspace(select: true)
        FocusSurfaceBroadcaster.shared.flush()
        try #require(manager.selectedTabId == third.id)
        let coordinator = ControlCommandCoordinator(context: TerminalController.shared)
        func selectLast(_ id: Int64) -> JSONValue? {
            let result = coordinator.handle(ControlRequest(id: .int(id), method: "workspace.last", params: [:]))
            FocusSurfaceBroadcaster.shared.flush()
            guard case .ok(.object(let payload))? = result else { return nil }
            return payload["workspace_id"]
        }

        // Act / Assert: the old navigateBack path went third -> second -> first.
        #expect(selectLast(1) == .string(second.id.uuidString))
        #expect(manager.selectedTabId == second.id)
        #expect(selectLast(2) == .string(third.id.uuidString))
        #expect(manager.selectedTabId == third.id)
    }

    private func makeManager() throws -> (TabManager, () -> Void) {
        let suiteName = "FocusLastToggleTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        let manager = TabManager(settings: UserDefaultsSettingsClient(defaults: defaults))
        return (manager, { defaults.removePersistentDomain(forName: suiteName) })
    }
}
