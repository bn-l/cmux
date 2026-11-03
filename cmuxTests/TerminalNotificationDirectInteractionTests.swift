import AppKit
import XCTest
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalNotificationStaleFocusDismissalTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TerminalController.shared.stop()
    }

    override func tearDown() {
        TerminalController.shared.stop()
        super.tearDown()
    }

    func testDirectInteractionDismissesNotificationWhenAppFocusStateIsStaleInactive() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let workspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        store.addNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Stale Focus",
            subtitle: "",
            body: ""
        )

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
        XCTAssertTrue(manager.dismissNotificationOnDirectInteraction(tabId: workspace.id, surfaceId: focusedPanelId))
        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }
}

/// Moving the pointer over the pane you are on acknowledges its alert. A real
/// terminal pane is hosted in a window with keyboard focus and wired into the
/// shared AppDelegate and store, so the pointer move runs the view's real path
/// through the notification dismissal model.
@MainActor
final class TerminalNotificationPointerMoveTests: XCTestCase {
    private let store = TerminalNotificationStore.shared
    private var appDelegate: AppDelegate!
    private var manager: TabManager!
    private var workspace: Workspace!
    private var panelId: UUID!
    private var window: NSWindow!
    private var view: GhosttyNSView!
    private var previousShared: AppDelegate?
    private var originalTabManager: TabManager?
    private var originalNotificationStore: TerminalNotificationStore?
    private var originalAppFocusOverride: Bool?

    override func setUpWithError() throws {
        try super.setUpWithError()
        TerminalController.shared.stop()
        previousShared = AppDelegate.shared
        appDelegate = previousShared ?? AppDelegate()
        originalTabManager = appDelegate.tabManager
        originalNotificationStore = appDelegate.notificationStore
        originalAppFocusOverride = AppFocusState.overrideIsFocused
        AppDelegate.shared = appDelegate
        manager = TabManager()
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        // cmux is the active app with a main window in front.
        AppFocusState.overrideIsFocused = true

        workspace = manager.addWorkspace(select: true)
        panelId = try XCTUnwrap(workspace.focusedPanelId)
        let panel = try XCTUnwrap(workspace.terminalPanel(for: panelId))
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        // ARC owns this window: AppKit's release-on-close would free it twice.
        window.isReleasedWhenClosed = false
        let contentView = try XCTUnwrap(window.contentView)
        panel.hostedView.frame = contentView.bounds
        panel.hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(panel.hostedView)
        window.makeKeyAndOrderFront(nil)
        view = try XCTUnwrap(Self.terminalView(in: panel.hostedView), "The hosted pane has no terminal view")
        XCTAssertEqual(view.terminalSurface?.id, panelId, "The terminal view must belong to the pane")
        XCTAssertEqual(view.terminalSurface?.tabId, workspace.id, "The terminal view must belong to the workspace")
        XCTAssertTrue(window.makeFirstResponder(view), "The pane must take keyboard focus")
    }

    override func tearDown() {
        window?.close()
        if let manager, let workspace, manager.tabs.contains(where: { $0.id == workspace.id }) {
            manager.closeWorkspace(workspace)
        }
        store.replaceNotificationsForTesting([])
        store.resetNotificationDeliveryHandlerForTesting()
        appDelegate?.tabManager = originalTabManager
        appDelegate?.notificationStore = originalNotificationStore
        AppFocusState.overrideIsFocused = originalAppFocusOverride
        AppDelegate.shared = previousShared
        TerminalController.shared.stop()
        super.tearDown()
    }

    func testMovingThePointerOverTheFocusedPaneAcknowledgesItsAlert() throws {
        let alert = alertArrivedWhileOnPane()
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId), "Precondition: the pane is ringed")

        try movePointer()

        XCTAssertEqual(isRead(alert), true)
        XCTAssertFalse(
            store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId),
            "The ring on the pane is gone too"
        )
    }

    func testPointerMoveOverAPaneWithoutKeyboardFocusLeavesItsAlert() throws {
        let alert = alertArrivedWhileOnPane()
        let otherControl = NSTextField(frame: NSRect(x: 0, y: 0, width: 80, height: 20))
        window.contentView?.addSubview(otherControl)
        XCTAssertTrue(window.makeFirstResponder(otherControl), "Precondition: keyboard focus is elsewhere")

        let acknowledged = view.acknowledgeNotificationOnPointerMove()

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(isRead(alert), false)
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))
    }

    func testPointerMoveWhileCmuxIsNotTheActiveAppLeavesTheAlert() {
        let alert = alertArrivedWhileOnPane()
        AppFocusState.overrideIsFocused = false

        let acknowledged = view.acknowledgeNotificationOnPointerMove()

        XCTAssertFalse(acknowledged)
        XCTAssertEqual(isRead(alert), false)
        XCTAssertTrue(store.hasVisibleNotificationIndicator(forTabId: workspace.id, surfaceId: panelId))
    }

    func testPointerMoveKeepsAPaneTheUserMarkedUnread() throws {
        let alert = alertArrivedWhileOnPane()
        workspace.markPanelUnread(panelId)
        XCTAssertTrue(workspace.manualUnreadPanelIds.contains(panelId), "Precondition: the pane is marked unread by hand")

        try movePointer()

        XCTAssertEqual(isRead(alert), true)
        XCTAssertTrue(
            workspace.manualUnreadPanelIds.contains(panelId),
            "A hand-set unread mark is a reminder; pointer movement must not clear it"
        )
    }

    /// An unread alert for the pane that arrived while the user was on it, which
    /// also rings the pane (the store does this when it suppresses the banner).
    private func alertArrivedWhileOnPane() -> TerminalNotification {
        let notification = TerminalNotification(
            id: UUID(),
            tabId: workspace.id,
            surfaceId: panelId,
            title: "Claude Code",
            subtitle: "Completed",
            body: "",
            createdAt: Date(),
            isRead: false
        )
        store.replaceNotificationsForTesting([notification])
        store.setFocusedReadIndicator(forTabId: workspace.id, surfaceId: panelId)
        return notification
    }

    private func isRead(_ notification: TerminalNotification) -> Bool? {
        store.notifications.first { $0.id == notification.id }?.isRead
    }

    private func movePointer() throws {
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .mouseMoved,
            location: NSPoint(x: 60, y: 60),
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        ))
        view.mouseMoved(with: event)
    }

    private static func terminalView(in hostedView: GhosttySurfaceScrollView) -> GhosttyNSView? {
        var stack: [NSView] = [hostedView]
        while let current = stack.popLast() {
            if let terminalView = current as? GhosttyNSView {
                return terminalView
            }
            stack.append(contentsOf: current.subviews)
        }
        return nil
    }
}
