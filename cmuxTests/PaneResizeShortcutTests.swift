import AppKit
import Bonsplit
import CmuxSettings
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Pane resize shortcuts (upstream manaflow-ai/cmux#4025): Ctrl+Shift+H/J/K/L
/// by default, key repeat, live `app.paneResizeStepPixels`, remapping.
@Suite("Pane resize shortcuts", .serialized)
@MainActor
struct PaneResizeShortcutTests {
    private static let stepKey = PaneResizeStepSettings.key

    @Test func defaultsAreControlShiftHJKL() {
        #expect(KeyboardShortcutSettings.Action.resizePaneLeft.defaultShortcut
            == StoredShortcut(key: "h", command: false, shift: true, option: false, control: true))
        #expect(KeyboardShortcutSettings.Action.resizePaneDown.defaultShortcut
            == StoredShortcut(key: "j", command: false, shift: true, option: false, control: true))
        #expect(KeyboardShortcutSettings.Action.resizePaneUp.defaultShortcut
            == StoredShortcut(key: "k", command: false, shift: true, option: false, control: true))
        #expect(KeyboardShortcutSettings.Action.resizePaneRight.defaultShortcut
            == StoredShortcut(key: "l", command: false, shift: true, option: false, control: true))
        #expect(KeyboardShortcutSettings.Action(rawValue: "resize-pane-left") == .resizePaneLeft)
    }

    @Test(arguments: ["left", "right", "up", "down"])
    func configuredShortcutAndRepeatMoveDivider(direction: String) throws {
        // Arrange
        let delegate = try #require(AppDelegate.shared)
        let action = try #require(KeyboardShortcutSettings.Action(rawValue: "resize-pane-\(direction)"))
        let originalStore = KeyboardShortcutSettings.installIsolatedTestFileStore(prefix: "pane-resize")
        let defaults = UserDefaults.standard
        let originalShortcut = defaults.object(forKey: action.defaultsKey)
        let originalStep = defaults.object(forKey: Self.stepKey)
        defer {
            if let originalShortcut { defaults.set(originalShortcut, forKey: action.defaultsKey) }
            else { defaults.removeObject(forKey: action.defaultsKey) }
            if let originalStep { defaults.set(originalStep, forKey: Self.stepKey) }
            else { defaults.removeObject(forKey: Self.stepKey) }
            KeyboardShortcutSettings.settingsFileStore = originalStore
        }

        let windowId = delegate.createMainWindow()
        let window = try #require(delegate.mainWindow(for: windowId))
        defer { window.performClose(nil) }
        let manager = try #require(delegate.tabManagerFor(windowId: windowId))
        let workspace = try #require(manager.selectedWorkspace)
        let first = try #require(workspace.focusedPanelId)
        let horizontal = direction == "left" || direction == "right"
        let second = try #require(workspace.newTerminalSplit(
            from: first,
            orientation: horizontal ? .horizontal : .vertical
        ))
        let negative = direction == "left" || direction == "up"
        let focused = negative ? second.id : first
        workspace.focusPanel(focused)
        window.makeKeyAndOrderFront(nil)
        window.contentView?.layoutSubtreeIfNeeded()
        let controller = workspace.bonsplitController
        controller.setContainerFrame(CGRect(x: 0, y: 0, width: 1000, height: 1000))
        let split = try rootSplit(controller)
        #expect(controller.setDividerPosition(0.5, forSplit: try #require(UUID(uuidString: split.id))))
        workspace.didProgrammaticallyChangeSplitGeometry()

        let shortcut = StoredShortcut(key: "y", command: true, shift: true, option: false, control: true)
        KeyboardShortcutSettings.setShortcut(shortcut, for: action)
        defaults.set(25, forKey: Self.stepKey)
        let sign = negative ? -1.0 : 1.0

        // Act / Assert: one press then two repeats, 25 px of 1000 each.
        for index in 1...3 {
            let event = try keyEvent(in: window, repeat: index > 1)
            #expect(delegate.debugHandleCustomShortcut(event: event))
            let updated = try rootSplit(controller)
            #expect(abs(updated.dividerPosition - (0.5 + sign * 0.025 * Double(index))) < 0.000_001)
            #expect(workspace.focusedPanelId == focused, "Resizing does not move focus")
            try expectCachedFramesMatch(workspace)
        }

        // The step changes on the next event without a restart.
        defaults.set(50, forKey: Self.stepKey)
        #expect(delegate.debugHandleCustomShortcut(event: try keyEvent(in: window, repeat: true)))
        #expect(abs(try rootSplit(controller).dividerPosition - (0.5 + sign * 0.125)) < 0.000_001)

        // An unbound action no longer moves the divider.
        KeyboardShortcutSettings.setShortcut(.unbound, for: action)
        let before = try rootSplit(controller).dividerPosition
        _ = delegate.debugHandleCustomShortcut(event: try keyEvent(in: window, repeat: false))
        #expect(try rootSplit(controller).dividerPosition == before)
    }

    @Test(arguments: [1, 20, 200])
    func settingsFileAppliesStepAndRemapping(step: Int) throws {
        try withSettings("""
        {"app":{"paneResizeStepPixels":\(step)},
         "shortcuts":{"bindings":{"resize-pane-left":"cmd+ctrl+y","resize-pane-right":null}}}
        """) { store, defaults in
            #expect(defaults.integer(forKey: Self.stepKey) == step)
            #expect(store.override(for: .resizePaneLeft) == StoredShortcut(key: "y", command: true, shift: false, option: false, control: true))
            #expect(store.override(for: .resizePaneRight) == .unbound)
        }
    }

    @Test(arguments: ["0", "201", "-1", "1.5", "true", "\"bad\""])
    func invalidStepDoesNotDiscardOtherAppSettings(value: String) throws {
        try withSettings("""
        {"app":{"paneResizeStepPixels":\(value),"confirmQuit":"never"}}
        """) { _, defaults in
            #expect(defaults.object(forKey: Self.stepKey) == nil)
            #expect(defaults.string(forKey: AppCatalogSection().confirmQuitMode.userDefaultsKey) == "never")
        }
    }

    // MARK: - Helpers

    /// The fork's settings file store writes to `UserDefaults.standard`, so
    /// the keys it may touch are saved and restored around each case.
    private func withSettings(
        _ json: String,
        body: (KeyboardShortcutSettingsFileStore, UserDefaults) throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        let isolatedKeys = [
            Self.stepKey,
            AppCatalogSection().confirmQuitMode.userDefaultsKey,
            KeyboardShortcutSettings.Action.resizePaneLeft.defaultsKey,
            KeyboardShortcutSettings.Action.resizePaneRight.defaultsKey,
            "cmux.settingsFile.backups.v1",
            "cmux.settingsFile.importedManagedDefaults.v1",
        ]
        let previous = isolatedKeys.reduce(into: [String: Any]()) { $0[$1] = defaults.object(forKey: $1) }
        isolatedKeys.forEach { defaults.removeObject(forKey: $0) }
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("PaneResizeShortcutTests.\(UUID().uuidString).json")
        defer {
            for key in isolatedKeys {
                if let value = previous[key] { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
            try? FileManager.default.removeItem(at: file)
        }
        try json.write(to: file, atomically: true, encoding: .utf8)
        let store = KeyboardShortcutSettingsFileStore(
            primaryPath: file.path,
            fallbackPath: nil,
            additionalFallbackPaths: [],
            startWatching: false
        )
        try body(store, defaults)
    }

    private func rootSplit(_ controller: BonsplitController) throws -> ExternalSplitNode {
        guard case .split(let split) = controller.treeSnapshot() else {
            throw TestFailure.missingSplit
        }
        return split
    }

    private func keyEvent(in window: NSWindow, repeat isRepeat: Bool) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: [.command, .control, .shift],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil,
            characters: "y", charactersIgnoringModifiers: "y",
            isARepeat: isRepeat, keyCode: 16
        ))
    }

    private func expectCachedFramesMatch(_ workspace: Workspace) throws {
        let cached = try #require(workspace.tmuxLayoutSnapshot)
        let live = workspace.bonsplitController.layoutSnapshot()
        #expect(cached.panes.count == live.panes.count)
        for pane in live.panes {
            let previous = try #require(cached.panes.first { $0.paneId == pane.paneId })
            #expect(previous.frame == pane.frame)
        }
    }

    private enum TestFailure: Error { case missingSplit }
}
