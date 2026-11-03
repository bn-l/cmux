import Bonsplit
import CmuxSettings
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Divider double-click equalizes (upstream manaflow-ai/cmux#21941): bonsplit
/// offers the click through `splitTabBar(_:didDoubleClickDivider:)`, and the
/// workspace equalizes only the clicked divider's same-direction run.
@MainActor
final class DividerDoubleClickEqualizeTests: XCTestCase {
    private let defaultsKey = SettingCatalog().app.equalizeSplitsOnDividerDoubleClick.userDefaultsKey
    private let onCreateKey = SettingCatalog().app.equalizeSplitsOnCreate.userDefaultsKey
    private var savedValues: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        for key in [defaultsKey, onCreateKey] {
            savedValues[key] = UserDefaults.standard.object(forKey: key)
        }
        // Splits must start at 50/50 so the fixture controls every ratio.
        UserDefaults.standard.set(false, forKey: onCreateKey)
    }

    override func tearDown() {
        for key in [defaultsKey, onCreateKey] {
            if let value = savedValues[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    /// Top pane over a bottom row `A | (B | C)`, every divider at 0.25.
    private struct Fixture {
        let manager: TabManager
        let workspace: Workspace
        let verticalRootId: UUID
        let bottomOuterId: UUID
        let bottomInnerId: UUID
    }

    private func makeFixture() throws -> Fixture {
        let manager = TabManager()
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let top = try XCTUnwrap(workspace.focusedPanelId)
        let bottomA = try XCTUnwrap(manager.createSplit(tabId: workspace.id, surfaceId: top, direction: .down))
        let bottomB = try XCTUnwrap(manager.createSplit(tabId: workspace.id, surfaceId: bottomA, direction: .right))
        XCTAssertNotNil(manager.createSplit(tabId: workspace.id, surfaceId: bottomB, direction: .right))
        let controller = workspace.bonsplitController
        let root = try XCTUnwrap(splitNode(controller.treeSnapshot()))
        XCTAssertEqual(root.orientation, "vertical")
        let outer = try XCTUnwrap(splitNode(root.second))
        XCTAssertEqual(outer.orientation, "horizontal")
        let inner = try XCTUnwrap(splitNode(outer.second))
        XCTAssertEqual(inner.orientation, "horizontal")
        let ids = try [root.id, outer.id, inner.id].map { try XCTUnwrap(UUID(uuidString: $0)) }
        for id in ids {
            XCTAssertTrue(controller.setDividerPosition(0.25, forSplit: id, fromExternal: true))
        }
        return Fixture(manager: manager, workspace: workspace, verticalRootId: ids[0], bottomOuterId: ids[1], bottomInnerId: ids[2])
    }

    func testDoubleClickEqualizesTheClickedRunAndLeavesTheOtherAxisAlone() throws {
        // Arrange
        UserDefaults.standard.removeObject(forKey: defaultsKey) // default: on
        let fixture = try makeFixture()
        let controller = fixture.workspace.bonsplitController
        let panesBefore = controller.allPaneIds
        let focusedBefore = controller.focusedPaneId
        let delegate: any BonsplitDelegate = fixture.workspace

        // Act: the inner divider of the bottom row.
        let handled = delegate.splitTabBar(controller, didDoubleClickDivider: fixture.bottomInnerId)

        // Assert: the bottom row becomes thirds, the vertical divider stays.
        XCTAssertTrue(handled)
        XCTAssertEqual(try position(of: fixture.bottomOuterId, in: controller), 1.0 / 3.0, accuracy: 0.000_1)
        XCTAssertEqual(try position(of: fixture.bottomInnerId, in: controller), 0.5, accuracy: 0.000_1)
        XCTAssertEqual(try position(of: fixture.verticalRootId, in: controller), 0.25, accuracy: 0.000_1)
        XCTAssertEqual(controller.allPaneIds, panesBefore)
        XCTAssertEqual(controller.focusedPaneId, focusedBefore, "Focus does not move")
    }

    func testOuterDividerOfTheRunGivesTheSameThirds() throws {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        let fixture = try makeFixture()
        let controller = fixture.workspace.bonsplitController

        XCTAssertTrue(fixture.workspace.splitTabBar(controller, didDoubleClickDivider: fixture.bottomOuterId))

        XCTAssertEqual(try position(of: fixture.bottomOuterId, in: controller), 1.0 / 3.0, accuracy: 0.000_1)
        XCTAssertEqual(try position(of: fixture.bottomInnerId, in: controller), 0.5, accuracy: 0.000_1)
        XCTAssertEqual(try position(of: fixture.verticalRootId, in: controller), 0.25, accuracy: 0.000_1)
    }

    func testDeclinedClicksLeaveEveryDividerAndNativeHandling() throws {
        let fixture = try makeFixture()
        let workspace = fixture.workspace
        let controller = workspace.bonsplitController

        UserDefaults.standard.set(false, forKey: defaultsKey)
        XCTAssertFalse(workspace.splitTabBar(controller, didDoubleClickDivider: fixture.bottomInnerId), "Setting off")
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        XCTAssertFalse(workspace.splitTabBar(BonsplitController(), didDoubleClickDivider: fixture.bottomInnerId), "Foreign controller")
        XCTAssertFalse(workspace.splitTabBar(controller, didDoubleClickDivider: UUID()), "Unknown split")
        workspace.isRemoteTmuxMirror = true
        XCTAssertFalse(workspace.splitTabBar(controller, didDoubleClickDivider: fixture.bottomInnerId), "Remote tmux mirror")
        workspace.isRemoteTmuxMirror = false

        for id in [fixture.verticalRootId, fixture.bottomOuterId, fixture.bottomInnerId] {
            XCTAssertEqual(try position(of: id, in: controller), 0.25, accuracy: 0.000_1)
        }
    }

    func testSettingsFileTurnsTheDoubleClickOff() throws {
        let defaults = UserDefaults.standard
        let isolatedKeys = [defaultsKey, "cmux.settingsFile.backups.v1", "cmux.settingsFile.importedManagedDefaults.v1"]
        let previous = isolatedKeys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        defer {
            for key in isolatedKeys {
                if let value = previous[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        isolatedKeys.forEach { defaults.removeObject(forKey: $0) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-divider-double-click-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        func load(_ value: String) throws -> Any? {
            let url = directory.appendingPathComponent("\(UUID().uuidString).json")
            try Data("{\"app\":{\"equalizeSplitsOnDividerDoubleClick\":\(value)}}".utf8).write(to: url)
            _ = KeyboardShortcutSettingsFileStore(primaryPath: url.path, fallbackPath: nil, startWatching: false)
            return defaults.object(forKey: defaultsKey)
        }

        XCTAssertEqual(try load("false") as? Bool, false)
        XCTAssertEqual(try load("true") as? Bool, true)
        XCTAssertTrue(CmuxSettingsFileStore.supportedSettingsJSONPaths.contains("app.equalizeSplitsOnDividerDoubleClick"))
    }

    private func position(of splitId: UUID, in controller: BonsplitController) throws -> Double {
        func find(_ node: ExternalTreeNode) -> ExternalSplitNode? {
            guard case .split(let split) = node else { return nil }
            if split.id == splitId.uuidString { return split }
            return find(split.first) ?? find(split.second)
        }
        return Double(try XCTUnwrap(find(controller.treeSnapshot())).dividerPosition)
    }

    private func splitNode(_ node: ExternalTreeNode) -> ExternalSplitNode? {
        if case .split(let split) = node { return split }
        return nil
    }
}
