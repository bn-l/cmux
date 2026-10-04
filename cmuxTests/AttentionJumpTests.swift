import AppKit
import CmuxSettings
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// A registered main window over a fresh `TabManager`, wired into the shared
/// `AppDelegate` and notification store the way the app wires them, so the
/// attention jump runs its real path: store + agent lifecycle snapshots, the
/// focused-target resolver, and the window/workspace open routing.
@MainActor
private final class AttentionJumpFixture {
    let appDelegate: AppDelegate
    let store = TerminalNotificationStore.shared
    let manager = TabManager()
    let window: NSWindow
    private let windowId: UUID
    private let previousShared: AppDelegate?
    private let originalTabManager: TabManager?
    private let originalNotificationStore: TerminalNotificationStore?
    private let originalAppFocusOverride: Bool?
    static let jumpShowsWorkspaceNameKey = NotificationsCatalogSection().jumpShowsWorkspaceName.userDefaultsKey
    private let originalJumpShowsWorkspaceName: Any?

    init() {
        previousShared = AppDelegate.shared
        appDelegate = previousShared ?? AppDelegate()
        originalTabManager = appDelegate.tabManager
        originalNotificationStore = appDelegate.notificationStore
        originalAppFocusOverride = AppFocusState.overrideIsFocused
        originalJumpShowsWorkspaceName = UserDefaults.standard.object(forKey: Self.jumpShowsWorkspaceNameKey)
        UserDefaults.standard.removeObject(forKey: Self.jumpShowsWorkspaceNameKey)

        AppDelegate.shared = appDelegate
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        // Inactive app: selecting a workspace must not auto-read its
        // notifications, so read state changes only through the jump itself.
        AppFocusState.overrideIsFocused = false
        store.replaceNotificationsForTesting([])

        windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        // ARC owns this window: AppKit's default release-on-close would free it
        // a second time once the close animation finishes, crashing a later test.
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
        window.makeKeyAndOrderFront(nil)
    }

    func tearDown() {
        appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
        window.close()
        for workspace in manager.tabs {
            manager.closeWorkspace(workspace)
        }
        store.replaceNotificationsForTesting([])
        appDelegate.tabManager = originalTabManager
        appDelegate.notificationStore = originalNotificationStore
        AppFocusState.overrideIsFocused = originalAppFocusOverride
        AppDelegate.shared = previousShared
        if let originalJumpShowsWorkspaceName {
            UserDefaults.standard.set(originalJumpShowsWorkspaceName, forKey: Self.jumpShowsWorkspaceNameKey)
        } else {
            UserDefaults.standard.removeObject(forKey: Self.jumpShowsWorkspaceNameKey)
        }
    }

    /// The workspace-name flash showing over the fixture window, if any.
    var flash: WorkspaceNameFlash? {
        WorkspaceNameFlashOverlayController.existingController(for: window)?.currentFlash
    }

    func workspace(_ title: String, select: Bool = false) throws -> (workspace: Workspace, panelId: UUID) {
        let workspace = manager.addWorkspace(title: title, select: select)
        return (workspace, try #require(workspace.focusedPanelId))
    }

    func block(_ target: (workspace: Workspace, panelId: UUID)) {
        target.workspace.setAgentLifecycle(key: "claude_code", panelId: target.panelId, lifecycle: .needsInput)
    }

    func notification(
        for target: (workspace: Workspace, panelId: UUID),
        createdAt: Date,
        isRead: Bool
    ) -> TerminalNotification {
        TerminalNotification(
            id: UUID(),
            tabId: target.workspace.id,
            surfaceId: target.panelId,
            title: "Agent",
            subtitle: "",
            body: "",
            createdAt: createdAt,
            isRead: isRead
        )
    }

    /// The workspace and panel the user is on after a jump.
    var focused: (workspaceId: UUID?, panelId: UUID?) {
        let workspaceId = manager.selectedTabId
        return (workspaceId, workspaceId.flatMap { manager.focusedSurfaceId(for: $0) })
    }
}

@MainActor
@Suite("Attention jump", .serialized)
struct AttentionJumpTests {
    @Test("a blocked agent is visited before an older unread notification and stays queued after the visit")
    func blockedAgentFirstThenUnreadThenBackToAgent() throws {
        let fixture = AttentionJumpFixture()
        defer { fixture.tearDown() }
        let home = try fixture.workspace("Home", select: true)
        let blocked = try fixture.workspace("Blocked agent")
        let done = try fixture.workspace("Finished agent")
        let doneNotification = fixture.notification(for: done, createdAt: Date().addingTimeInterval(-600), isRead: false)
        fixture.store.replaceNotificationsForTesting([doneNotification])
        // Blocked after the other agent finished: newest-first order would
        // pick the finished one; attention order picks the blocked one.
        fixture.block(blocked)

        _ = fixture.appDelegate.jumpToLatestUnread()
        let first = fixture.focused
        let doneStillUnread = fixture.store.notifications.first { $0.id == doneNotification.id }?.isRead == false

        _ = fixture.appDelegate.jumpToLatestUnread()
        let second = fixture.focused
        let doneReadAfterVisit = fixture.store.notifications.first { $0.id == doneNotification.id }?.isRead == true

        _ = fixture.appDelegate.jumpToLatestUnread()
        let third = fixture.focused

        blocked.workspace.setAgentLifecycle(key: "claude_code", panelId: blocked.panelId, lifecycle: .running)
        fixture.manager.selectTab(home.workspace)
        _ = fixture.appDelegate.jumpToLatestUnread()
        let afterEverythingHandled = fixture.focused

        #expect(first.workspaceId == blocked.workspace.id)
        #expect(first.panelId == blocked.panelId)
        #expect(doneStillUnread)
        #expect(second.workspaceId == done.workspace.id, "The blocked agent is focused, so the jump moves past it")
        #expect(doneReadAfterVisit)
        #expect(third.workspaceId == blocked.workspace.id, "Viewing a blocked agent does not unblock it")
        #expect(afterEverythingHandled.workspaceId == home.workspace.id, "Nothing needs attention, so the jump stays put")
    }

    @Test("sending a blocked agent to the back keeps it behind newer blocked agents and unread notifications")
    func sendToBackKeepsDeferredAgentBehindOtherWork() throws {
        let fixture = AttentionJumpFixture()
        defer { fixture.tearDown() }
        let deferred = try fixture.workspace("Deferred agent", select: true)
        let laterBlocked = try fixture.workspace("Later blocked agent")
        let done = try fixture.workspace("Finished agent")
        // The deferred agent's prompt notification was already seen.
        let deferredNotification = fixture.notification(for: deferred, createdAt: Date().addingTimeInterval(-60), isRead: true)
        let doneNotification = fixture.notification(for: done, createdAt: Date().addingTimeInterval(-600), isRead: false)
        fixture.store.replaceNotificationsForTesting([deferredNotification, doneNotification])
        fixture.block(deferred)
        fixture.block(laterBlocked)

        _ = fixture.appDelegate.markFocusedNotificationAsOldestUnreadAndJumpToNextLatestUnread(preferredWindow: fixture.window)
        let afterSendToBack = fixture.focused
        let deferredState = fixture.store.notifications.first { $0.id == deferredNotification.id }

        var visits: [UUID?] = []
        for _ in 0..<3 {
            _ = fixture.appDelegate.jumpToLatestUnread()
            visits.append(fixture.focused.workspaceId)
        }

        #expect(afterSendToBack.workspaceId == laterBlocked.workspace.id)
        #expect(deferredState?.isRead == false)
        #expect(deferredState?.deferredAt != nil)
        // From the later agent: the unread notification, then (from a panel no
        // longer in the queue) the first non-deferred entry, and only then the
        // deferred agent. Without the deferral the second visit would be the
        // older deferred agent.
        #expect(visits == [done.workspace.id, laterBlocked.workspace.id, deferred.workspace.id])
    }

    @Test("marking as oldest unread stamps only the moved notification as deferred")
    func markOldestUnreadStampsDeferral() {
        let fixture = AttentionJumpFixture()
        defer { fixture.tearDown() }
        let (tabA, tabB) = (UUID(), UUID())
        let moved = TerminalNotification(
            id: UUID(), tabId: tabA, surfaceId: nil, title: "A", subtitle: "", body: "",
            createdAt: Date(), isRead: true
        )
        let untouched = TerminalNotification(
            id: UUID(), tabId: tabB, surfaceId: nil, title: "B", subtitle: "", body: "",
            createdAt: Date().addingTimeInterval(-1), isRead: false
        )
        fixture.store.replaceNotificationsForTesting([moved, untouched])
        let before = Date()

        let movedId = fixture.store.markLatestNotificationAsOldestUnread(forTabId: tabA, surfaceId: nil)

        let movedAfter = fixture.store.notifications.first { $0.id == moved.id }
        let untouchedAfter = fixture.store.notifications.first { $0.id == untouched.id }
        #expect(movedId == moved.id)
        #expect(movedAfter?.isRead == false)
        #expect((movedAfter?.deferredAt).map { $0 >= before } == true)
        #expect(untouchedAfter?.deferredAt == nil)
    }
}

@MainActor
@Suite("Workspace name flash after an attention jump", .serialized)
struct AttentionJumpWorkspaceNameFlashTests {
    @Test("each jump into another workspace flashes that workspace's name and color over the landing window")
    func jumpIntoAnotherWorkspaceFlashesItsName() throws {
        let fixture = AttentionJumpFixture()
        defer { fixture.tearDown() }
        _ = try fixture.workspace("Home", select: true)
        let blocked = try fixture.workspace("Blocked agent")
        let done = try fixture.workspace("Finished agent")
        blocked.workspace.setCustomColor("#c0392b")
        fixture.store.replaceNotificationsForTesting([
            fixture.notification(for: done, createdAt: Date().addingTimeInterval(-600), isRead: false),
        ])
        fixture.block(blocked)

        _ = fixture.appDelegate.jumpToLatestUnread()
        let first = fixture.flash
        let firstLanding = fixture.focused.workspaceId
        _ = fixture.appDelegate.jumpToLatestUnread()
        let second = fixture.flash
        let secondLanding = fixture.focused.workspaceId

        #expect(firstLanding == blocked.workspace.id)
        #expect(first?.title == "Blocked agent")
        #expect(first?.colorHex == "#C0392B")
        #expect(secondLanding == done.workspace.id)
        #expect(second?.title == "Finished agent")
        #expect(second?.colorHex == nil, "A workspace without a color gets no accent")
        #expect(first?.id != second?.id, "Each jump restarts the flash")
    }

    @Test("a jump that stays in the focused workspace does not flash")
    func jumpWithinFocusedWorkspaceDoesNotFlash() throws {
        let fixture = AttentionJumpFixture()
        defer { fixture.tearDown() }
        let home = try fixture.workspace("Home", select: true)
        // Workspace-level (no surface), so it is not the focused pane's own
        // entry and the jump opens it inside the workspace already in front.
        let workspaceLevel = TerminalNotification(
            id: UUID(), tabId: home.workspace.id, surfaceId: nil, title: "Agent", subtitle: "", body: "",
            createdAt: Date(), isRead: false
        )
        fixture.store.replaceNotificationsForTesting([workspaceLevel])

        _ = fixture.appDelegate.jumpToLatestUnread()

        #expect(fixture.store.notifications.first { $0.id == workspaceLevel.id }?.isRead == true, "The jump opened the notification")
        #expect(fixture.focused.workspaceId == home.workspace.id)
        #expect(fixture.flash == nil)
    }

    @Test("with the setting off a jump into another workspace does not flash")
    func settingOffSuppressesFlash() throws {
        let fixture = AttentionJumpFixture()
        defer { fixture.tearDown() }
        _ = try fixture.workspace("Home", select: true)
        let blocked = try fixture.workspace("Blocked agent")
        fixture.block(blocked)
        UserDefaults.standard.set(false, forKey: AttentionJumpFixture.jumpShowsWorkspaceNameKey)

        _ = fixture.appDelegate.jumpToLatestUnread()

        #expect(fixture.focused.workspaceId == blocked.workspace.id)
        #expect(fixture.flash == nil)
    }
}

@MainActor
@Suite("Agent needs-input timestamps")
struct AgentNeedsInputSinceTests {
    /// A settable clock for the lifecycle model.
    @MainActor
    final class Clock {
        var now = Date(timeIntervalSince1970: 100)
    }

    @Test("the time is recorded on entering needs-input, kept while blocked, and reset after the agent moves on")
    func needsInputSinceLifecycle() {
        let clock = Clock()
        let model = WorkspaceSidebarAgentRuntimeObservationModel(now: { clock.now })
        let (panel, other) = (UUID(), UUID())

        model.setAgentLifecycleStatesByPanelId([panel: ["claude_code": .needsInput]])
        let entered = model.needsInputSinceByPanelId[panel]

        clock.now = Date(timeIntervalSince1970: 200)
        model.setAgentLifecycleStatesByPanelId([panel: ["claude_code": .needsInput], other: ["codex": .running]])
        let stillBlocked = model.needsInputSinceByPanelId[panel]
        let runningPanel = model.needsInputSinceByPanelId[other]

        clock.now = Date(timeIntervalSince1970: 300)
        model.setAgentLifecycleStatesByPanelId([panel: ["claude_code": .running]])
        let afterRunning = model.needsInputSinceByPanelId[panel]

        clock.now = Date(timeIntervalSince1970: 400)
        model.setAgentLifecycleStatesByPanelId([panel: ["claude_code": .needsInput]])
        let reentered = model.needsInputSinceByPanelId[panel]

        #expect(entered == Date(timeIntervalSince1970: 100))
        #expect(stillBlocked == Date(timeIntervalSince1970: 100))
        #expect(runningPanel == nil)
        #expect(afterRunning == nil)
        #expect(reentered == Date(timeIntervalSince1970: 400))
    }

    @Test(
        "a panel only counts as needing input when that wins over its other agent keys",
        arguments: [
            (["claude_code": AgentHibernationLifecycleState.needsInput, "codex": .running], false),
            (["claude_code": .needsInput, "codex": .idle], true),
            (["claude_code": .needsInput, "codex": .unknown], true),
            (["claude_code": .idle], false),
            (["manual": .needsInput], false),
            (["manual": .running, "claude_code": .needsInput], true),
        ]
    )
    func aggregatedNeedsInput(states: [String: AgentHibernationLifecycleState], counts: Bool) {
        let model = WorkspaceSidebarAgentRuntimeObservationModel()
        let panel = UUID()

        model.setAgentLifecycleStatesByPanelId([panel: states])

        #expect((model.needsInputSinceByPanelId[panel] != nil) == counts)
    }
}
