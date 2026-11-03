import XCTest
import AppKit
import CmuxSettings
import Darwin
#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
final class TerminalNotificationQueueTests: XCTestCase {
    override func setUp() {
        super.setUp()
        TerminalController.shared.stop()
    }

    override func tearDown() {
        TerminalController.shared.stop()
        super.tearDown()
    }

    func testNotifyTargetAsyncQueuesNotificationForResolvedSurface() async throws {
        let socketPath = makeSocketPath("notify-async")
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        let notificationQueued = expectation(description: "notification queued")
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in
            notificationQueued.fulfill()
        }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in
            notificationQueued.fulfill()
        }
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
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalController.shared.start(
            tabManager: manager,
            socketPath: socketPath,
            accessMode: .allowAll
        )
        try waitForSocket(at: socketPath)

        let payload = "Async|Queued|Body"
        let command = "notify_target_async \(workspace.id.uuidString) \(focusedPanelId.uuidString) \(payload)"
        let responses = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    continuation.resume(returning: try self.sendCommands([command], to: socketPath))
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }

        XCTAssertEqual(responses, ["OK"])
        await fulfillment(of: [notificationQueued], timeout: 1.0)
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    func testNotifyTargetAsyncRequiresPayload() {
        let args = "\(UUID().uuidString) \(UUID().uuidString)"
        let response = TerminalController.debugNotifyTargetQueuedResponseForTesting(args)

        XCTAssertEqual(
            response,
            "ERROR: Usage: notify_target_async <workspace_uuid> <surface_uuid> <title>|<subtitle>|<body>"
        )
    }

    func testClearNotificationsDropsQueuedNotifyBeforeDrain() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused
        var deliveredTitles: [String] = []
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredTitles.append(notification.title)
        }
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

        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Async",
            subtitle: "Queued",
            body: "Body"
        )
        store.clearNotifications(forTabId: workspace.id)
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertFalse(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
        XCTAssertFalse(store.notifications.contains { $0.tabId == workspace.id })
        XCTAssertEqual(deliveredTitles, [])
    }

    func testClearNotificationsIsBoundaryForFreshNotify() async throws {
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

        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Stale",
            subtitle: "Before clear",
            body: "Body"
        )
        TerminalMutationBus.shared.enqueueClearNotifications(forTabId: workspace.id)
        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Fresh",
            subtitle: "After clear",
            body: "Body"
        )

        TerminalMutationBus.shared.drainForTesting()

        let workspaceNotifications = store.notifications.filter { $0.tabId == workspace.id }
        XCTAssertEqual(workspaceNotifications.map(\.title), ["Fresh"])
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    func testQueuedClearAllDropsOnlyOlderQueuedNotify() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredTitles: [String] = []
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredTitles.append(notification.title)
        }
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

        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Stale",
            subtitle: "Before clear",
            body: "Body"
        )
        TerminalMutationBus.shared.enqueueClearAllNotifications()
        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Fresh",
            subtitle: "After clear",
            body: "Body"
        )
        TerminalMutationBus.shared.drainForTesting()

        let workspaceNotifications = store.notifications.filter { $0.tabId == workspace.id }
        XCTAssertEqual(workspaceNotifications.map(\.title), ["Fresh"])
        XCTAssertEqual(deliveredTitles, ["Fresh"])
        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    func testQueuedNotificationCoalescesRepeatedEventsForSameSurface() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredTitles: [String] = []
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredTitles.append(notification.title)
        }
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

        TerminalMutationBus.shared.setDrainsSuspendedForTesting(true)
        defer { TerminalMutationBus.shared.setDrainsSuspendedForTesting(false) }
        for title in ["First", "Second"] {
            TerminalMutationBus.shared.enqueueNotification(
                tabId: workspace.id,
                surfaceId: focusedPanelId,
                title: title,
                subtitle: "Same target",
                body: "Body"
            )
            if title == "First" { TerminalMutationBus.shared.enqueueMainActorMutation {} }
        }
        TerminalMutationBus.shared.drainForTesting()
        let workspaceNotifications = store.notifications.filter { $0.tabId == workspace.id }
        XCTAssertEqual(workspaceNotifications.map(\.title), ["Second"])
        XCTAssertEqual(deliveredTitles, ["Second"])
    }

    func testNotifyTargetAsyncCommandDoesNotCoalesceRepeatedEventsForSameSurface() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredTitles: [String] = []
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredTitles.append(notification.title)
        }
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

        TerminalMutationBus.shared.setDrainsSuspendedForTesting(true)
        defer { TerminalMutationBus.shared.setDrainsSuspendedForTesting(false) }

        for title in ["First", "Second"] {
            let response = TerminalController.debugNotifyTargetQueuedResponseForTesting(
                "\(workspace.id.uuidString) \(focusedPanelId.uuidString) \(title)|Completed|Body"
            )
            XCTAssertEqual(response, "OK")
        }

        TerminalMutationBus.shared.drainForTesting()

        let workspaceNotifications = store.notifications.filter { $0.tabId == workspace.id }
        XCTAssertEqual(workspaceNotifications.map(\.title), ["Second"])
        XCTAssertEqual(deliveredTitles, ["First", "Second"])
    }

    func testScopedDiscardDoesNotSplitUnrelatedNotificationCoalescing() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = appDelegate.tabManager ?? TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        var deliveredTitles: [String] = []
        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, notification in
            deliveredTitles.append(notification.title)
        }
        appDelegate.tabManager = manager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let clearedWorkspace = manager.addWorkspace(select: true)
        let unrelatedWorkspace = manager.addWorkspace(select: true)
        defer {
            if manager.tabs.contains(where: { $0.id == clearedWorkspace.id }) {
                manager.closeWorkspace(clearedWorkspace)
            }
            if manager.tabs.contains(where: { $0.id == unrelatedWorkspace.id }) {
                manager.closeWorkspace(unrelatedWorkspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let clearedPanelId = clearedWorkspace.focusedPanelId,
              let unrelatedPanelId = unrelatedWorkspace.focusedPanelId else {
            XCTFail("Expected workspaces with focused panels")
            return
        }

        TerminalMutationBus.shared.setDrainsSuspendedForTesting(true)
        defer { TerminalMutationBus.shared.setDrainsSuspendedForTesting(false) }

        TerminalMutationBus.shared.enqueueNotification(
            tabId: unrelatedWorkspace.id,
            surfaceId: unrelatedPanelId,
            title: "Stale unrelated",
            subtitle: "Before scoped discard",
            body: "Body"
        )
        TerminalMutationBus.shared.discardPendingNotifications(
            forTabId: clearedWorkspace.id,
            surfaceId: clearedPanelId
        )
        TerminalMutationBus.shared.enqueueNotification(
            tabId: unrelatedWorkspace.id,
            surfaceId: unrelatedPanelId,
            title: "Fresh unrelated",
            subtitle: "After scoped discard",
            body: "Body"
        )

        TerminalMutationBus.shared.drainForTesting()

        let unrelatedNotifications = store.notifications.filter { $0.tabId == unrelatedWorkspace.id }
        XCTAssertEqual(unrelatedNotifications.map(\.title), ["Fresh unrelated"])
        XCTAssertEqual(deliveredTitles, ["Fresh unrelated"])
    }

    func testQueuedNotificationResolvesWorkspaceInRegisteredWindowContext() throws {
        let store = TerminalNotificationStore.shared
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let activeManager = TabManager()
        let targetManager = TabManager()

        let originalTabManager = appDelegate.tabManager
        let originalNotificationStore = appDelegate.notificationStore
        let originalAppFocusOverride = AppFocusState.overrideIsFocused

        store.replaceNotificationsForTesting([])
        store.configureNotificationDeliveryHandlerForTesting { _, _ in }
        store.configureSuppressedNotificationFeedbackHandlerForTesting { _, _ in }
        appDelegate.tabManager = activeManager
        appDelegate.notificationStore = store
        AppFocusState.overrideIsFocused = false

        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: targetManager)
        let workspace = targetManager.addWorkspace(select: true)
        defer {
            if targetManager.tabs.contains(where: { $0.id == workspace.id }) {
                targetManager.closeWorkspace(workspace)
            }
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            store.resetSuppressedNotificationFeedbackHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
        }

        guard let focusedPanelId = workspace.focusedPanelId else {
            XCTFail("Expected selected workspace with a focused panel")
            return
        }

        TerminalMutationBus.shared.enqueueNotification(
            tabId: workspace.id,
            surfaceId: focusedPanelId,
            title: "Async",
            subtitle: "Queued",
            body: "Body"
        )
        TerminalMutationBus.shared.drainForTesting()

        XCTAssertTrue(store.hasUnreadNotification(forTabId: workspace.id, surfaceId: focusedPanelId))
    }

    func testUnregisterMainWindowContextForTestingRepointsActiveContext() {
        let appDelegate = AppDelegate()

        let managerA = TabManager()
        let managerB = TabManager()
        let windowAId = appDelegate.registerMainWindowContextForTesting(tabManager: managerA)
        let windowBId = appDelegate.registerMainWindowContextForTesting(tabManager: managerB)
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowAId)
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowBId)
            appDelegate.tabManager = nil
            appDelegate.sidebarState = nil
            appDelegate.sidebarSelectionState = nil
            TerminalController.shared.setActiveTabManager(nil)
        }

        appDelegate.tabManager = managerA
        TerminalController.shared.setActiveTabManager(managerA)

        appDelegate.unregisterMainWindowContextForTesting(windowId: windowAId)

        XCTAssertTrue(appDelegate.tabManager === managerB)
        XCTAssertNotNil(appDelegate.sidebarState)
        XCTAssertNotNil(appDelegate.sidebarSelectionState)

        appDelegate.unregisterMainWindowContextForTesting(windowId: windowBId)

        XCTAssertNil(appDelegate.tabManager)
        XCTAssertNil(appDelegate.sidebarState)
        XCTAssertNil(appDelegate.sidebarSelectionState)
    }

    func testReplacingMainActorMutationKeepsOnlyNewestEntryPerKey() throws {
        TerminalMutationBus.shared.setDrainsSuspendedForTesting(true)
        defer { TerminalMutationBus.shared.setDrainsSuspendedForTesting(false) }

        let tabId = UUID()
        let surfaceA = UUID()
        let surfaceB = UUID()
        let keyA = TerminalMutationReplaceKey(tabId: tabId, surfaceId: surfaceA, kind: .shellActivity)
        let keyB = TerminalMutationReplaceKey(tabId: tabId, surfaceId: surfaceB, kind: .shellActivity)
        // Same surface as keyA, different kind: must not cross-coalesce.
        let keyC = TerminalMutationReplaceKey(tabId: tabId, surfaceId: surfaceA, kind: .gitBranch)

        var applied: [String] = []
        TerminalMutationBus.shared.enqueueReplacingMainActorMutation(replaceKey: keyA) { applied.append("a1") }
        TerminalMutationBus.shared.enqueueReplacingMainActorMutation(replaceKey: keyB) { applied.append("b1") }
        TerminalMutationBus.shared.enqueueReplacingMainActorMutation(replaceKey: keyC) { applied.append("c1") }
        // Non-keyed mutations must never be replaced.
        TerminalMutationBus.shared.enqueueMainActorMutation { applied.append("plain") }
        TerminalMutationBus.shared.enqueueReplacingMainActorMutation(replaceKey: keyA) { applied.append("a2") }
        TerminalMutationBus.shared.enqueueReplacingMainActorMutation(replaceKey: keyA) { applied.append("a3") }

        TerminalMutationBus.shared.drainForTesting()

        // keyA coalesces to its newest closure at its latest enqueue position;
        // keyB, keyC, and the plain mutation are untouched in enqueue order.
        XCTAssertEqual(applied, ["b1", "c1", "plain", "a3"])
    }

    // MARK: - Agent idle reminder after the turn's finish alert
    //
    // Claude Code sends an idle reminder ("waiting for your input") about 60 s
    // after a turn ends. When that turn's finish alert already showed up it
    // repeats what the user was shown, so it must not replace the finish alert.
    // When it never showed up the reminder is the only signal and must notify.
    // Each test plays the exact socket commands the Claude hooks send against a
    // real controller, with drains held so mutations apply in arrival order.

    func testReminderAfterReadFinishAlertIsDropped() async throws {
        let fixture = try AgentReminderFixture(test: self, name: "rmd-read")
        defer { fixture.tearDown() }
        let finish = try await fixture.finishTurn(fixture.paneA)
        TerminalNotificationStore.shared.markRead(forTabId: fixture.workspaceId, surfaceId: fixture.paneA)

        try await fixture.send([fixture.reminder(fixture.paneA)])

        let pane = fixture.notifications(fixture.paneA)
        XCTAssertEqual(pane.map(\.id), [finish.id], "The read finish alert stays; no new entry")
        XCTAssertEqual(pane.first?.isRead, true)
        XCTAssertEqual(fixture.bannerSubtitles, [AgentReminderFixture.finishSubtitle], "No second banner")
    }

    func testReminderAfterUnreadFinishAlertLeavesItUntouched() async throws {
        let fixture = try AgentReminderFixture(test: self, name: "rmd-unread")
        defer { fixture.tearDown() }
        let finish = try await fixture.finishTurn(fixture.paneA)

        try await fixture.send([fixture.reminder(fixture.paneA)])

        let pane = fixture.notifications(fixture.paneA)
        XCTAssertEqual(pane.map(\.id), [finish.id], "Not replaced")
        XCTAssertEqual(pane.first?.isRead, false)
        XCTAssertEqual(pane.first?.subtitle, AgentReminderFixture.finishSubtitle, "Claude's summary is kept")
        XCTAssertEqual(pane.first?.body, AgentReminderFixture.finishBody)
        XCTAssertEqual(pane.first?.createdAt, finish.createdAt, "Its place in the attention queue is kept")
        XCTAssertEqual(fixture.bannerSubtitles, [AgentReminderFixture.finishSubtitle])
    }

    func testReminderAfterDismissedFinishAlertStaysDropped() async throws {
        let fixture = try AgentReminderFixture(test: self, name: "rmd-dism")
        defer { fixture.tearDown() }
        let finish = try await fixture.finishTurn(fixture.paneA)
        // The notifications list's dismiss button.
        TerminalNotificationStore.shared.remove(id: finish.id)

        try await fixture.send([fixture.reminder(fixture.paneA)])

        XCTAssertTrue(fixture.notifications(fixture.paneA).isEmpty, "A dismissed finish alert is not brought back")
        XCTAssertEqual(fixture.bannerSubtitles, [AgentReminderFixture.finishSubtitle])
    }

    func testReminderNotifiesWhenFinishAlertsAreTurnedOff() async throws {
        let fixture = try AgentReminderFixture(test: self, name: "rmd-off")
        defer { fixture.tearDown() }
        UserDefaults.standard.set("never", forKey: AgentReminderFixture.turnCompleteKey)
        try await fixture.sendStop(fixture.paneA)
        XCTAssertTrue(fixture.notifications(fixture.paneA).isEmpty, "Precondition: the finish alert is turned off")

        try await fixture.send([fixture.reminder(fixture.paneA)])

        let pane = fixture.notifications(fixture.paneA)
        XCTAssertEqual(pane.map(\.subtitle), [AgentReminderFixture.reminderSubtitle], "The reminder is the only signal")
        XCTAssertEqual(pane.first?.isRead, false)
        XCTAssertEqual(fixture.bannerSubtitles, [AgentReminderFixture.reminderSubtitle])
    }

    func testReminderNotifiesWhenTheNewTurnShowedNoFinishAlert() async throws {
        let fixture = try AgentReminderFixture(test: self, name: "rmd-turn")
        defer { fixture.tearDown() }
        try await fixture.finishTurn(fixture.paneA)
        TerminalNotificationStore.shared.markRead(forTabId: fixture.workspaceId, surfaceId: fixture.paneA)
        // The next prompt starts a new turn, which ends with no finish alert
        // (a Stop whose summary was empty sends only the lifecycle).
        try await fixture.send(fixture.turnStart(fixture.paneA) + [fixture.lifecycle(fixture.paneA, "idle")])

        try await fixture.send([fixture.reminder(fixture.paneA)])

        let pane = fixture.notifications(fixture.paneA)
        XCTAssertEqual(pane.map(\.subtitle), [AgentReminderFixture.reminderSubtitle], "The old turn's alert does not silence the new turn")
        XCTAssertEqual(pane.first?.isRead, false)
    }

    func testAnotherPanesToolUseKeepsThisPanesFinishAlertAndItsClaim() async throws {
        let fixture = try AgentReminderFixture(test: self, name: "rmd-othr")
        defer { fixture.tearDown() }
        let finish = try await fixture.finishTurn(fixture.paneA)
        TerminalNotificationStore.shared.markRead(forTabId: fixture.workspaceId, surfaceId: fixture.paneA)
        // Pane B's agent uses a tool: its hook clears pane B and reports B
        // running. Neither touches pane A or starts a turn there.
        try await fixture.send(fixture.turnStart(fixture.paneB))

        try await fixture.send([fixture.reminder(fixture.paneA)])

        let pane = fixture.notifications(fixture.paneA)
        XCTAssertEqual(pane.map(\.id), [finish.id], "Pane A's finish alert survives pane B's tool use and is not replaced")
        XCTAssertEqual(pane.first?.isRead, true)
        XCTAssertEqual(fixture.bannerSubtitles, [AgentReminderFixture.finishSubtitle])
    }

    func testFinishAlertWipedUnreadByAWorkspaceWideClearLetsTheReminderThrough() async throws {
        let fixture = try AgentReminderFixture(test: self, name: "rmd-wipe")
        defer { fixture.tearDown() }
        try await fixture.finishTurn(fixture.paneA)
        // Another client clears the whole workspace before pane A's alert was read.
        try await fixture.send([fixture.workspaceWideClear])
        XCTAssertTrue(fixture.notifications(fixture.paneA).isEmpty, "Precondition: pane A's unread alert was wiped")

        try await fixture.send([fixture.reminder(fixture.paneA)])

        let pane = fixture.notifications(fixture.paneA)
        XCTAssertEqual(pane.map(\.subtitle), [AgentReminderFixture.reminderSubtitle], "The user never saw the finish alert")
        XCTAssertEqual(pane.first?.isRead, false)
    }

    func testUntaggedNotificationAfterFinishAlertStillReplacesIt() async throws {
        let fixture = try AgentReminderFixture(test: self, name: "rmd-plain")
        defer { fixture.tearDown() }
        try await fixture.finishTurn(fixture.paneA)

        try await fixture.send([
            "notify_target_async \(fixture.workspaceId.uuidString) \(fixture.paneA.uuidString) Build|Deployed|staging is up",
        ])

        let pane = fixture.notifications(fixture.paneA)
        XCTAssertEqual(pane.map(\.subtitle), ["Deployed"], "Only agent idle reminders are held back")
        XCTAssertEqual(pane.first?.isRead, false)
    }

    /// A workspace with two terminal panes, a real control socket, held drains,
    /// and explicit agent notification settings, all restored on tear down.
    @MainActor
    private final class AgentReminderFixture {
        static let finishSubtitle = "Completed in proj"
        static let finishBody = "Refactored the parser and added tests."
        static let reminderSubtitle = "Waiting"
        static let turnCompleteKey = NotificationsCatalogSection().agentTurnComplete.userDefaultsKey
        static let idleReminderKey = NotificationsCatalogSection().agentIdleReminder.userDefaultsKey

        let workspaceId: UUID
        let paneA: UUID
        let paneB: UUID
        private(set) var bannerSubtitles: [String] = []
        private let test: TerminalNotificationQueueTests
        private let socketPath: String
        private let store = TerminalNotificationStore.shared
        private let appDelegate: AppDelegate
        private let manager: TabManager
        private let workspace: Workspace
        private let originalTabManager: TabManager?
        private let originalNotificationStore: TerminalNotificationStore?
        private let originalAppFocusOverride: Bool?
        private let originalTurnComplete: Any?
        private let originalIdleReminder: Any?

        init(test: TerminalNotificationQueueTests, name: String) throws {
            self.test = test
            socketPath = test.makeSocketPath(name)
            appDelegate = AppDelegate.shared ?? AppDelegate()
            manager = appDelegate.tabManager ?? TabManager()
            originalTabManager = appDelegate.tabManager
            originalNotificationStore = appDelegate.notificationStore
            originalAppFocusOverride = AppFocusState.overrideIsFocused
            originalTurnComplete = UserDefaults.standard.object(forKey: Self.turnCompleteKey)
            originalIdleReminder = UserDefaults.standard.object(forKey: Self.idleReminderKey)

            UserDefaults.standard.set("whenIdle", forKey: Self.turnCompleteKey)
            UserDefaults.standard.set(true, forKey: Self.idleReminderKey)
            store.replaceNotificationsForTesting([])
            appDelegate.tabManager = manager
            appDelegate.notificationStore = store
            // Not focused, so every recorded alert also reaches the banner handler.
            AppFocusState.overrideIsFocused = false

            workspace = manager.addWorkspace(select: true)
            workspaceId = workspace.id
            paneA = try XCTUnwrap(workspace.focusedPanelId)
            paneB = try XCTUnwrap(workspace.newTerminalSplit(from: paneA, orientation: .horizontal)?.id)
            store.configureNotificationDeliveryHandlerForTesting { [weak self] _, notification in
                self?.bannerSubtitles.append(notification.subtitle)
            }

            TerminalController.shared.start(tabManager: manager, socketPath: socketPath, accessMode: .allowAll)
            try test.waitForSocket(at: socketPath)
            TerminalMutationBus.shared.setDrainsSuspendedForTesting(true)
        }

        func tearDown() {
            TerminalMutationBus.shared.setDrainsSuspendedForTesting(false)
            TerminalController.shared.stop()
            if manager.tabs.contains(where: { $0.id == workspace.id }) {
                manager.closeWorkspace(workspace)
            }
            store.replaceNotificationsForTesting([])
            store.resetNotificationDeliveryHandlerForTesting()
            appDelegate.tabManager = originalTabManager
            appDelegate.notificationStore = originalNotificationStore
            AppFocusState.overrideIsFocused = originalAppFocusOverride
            Self.restore(originalTurnComplete, forKey: Self.turnCompleteKey)
            Self.restore(originalIdleReminder, forKey: Self.idleReminderKey)
        }

        /// Sends the commands over the socket in order, asserts each was
        /// accepted, then applies everything they queued.
        func send(_ commands: [String]) async throws {
            let socketPath = socketPath
            let test = test
            let responses = try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try test.sendCommands(commands, to: socketPath))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
            XCTAssertEqual(responses, Array(repeating: "OK", count: commands.count), "Commands: \(commands)")
            TerminalMutationBus.shared.drainForTesting()
        }

        /// What the Claude Stop hook sends: the lifecycle, then the finish alert.
        func sendStop(_ pane: UUID) async throws {
            try await send([
                lifecycle(pane, "idle"),
                "notify_target_async \(workspaceId.uuidString) \(pane.uuidString) Claude Code|\(Self.finishSubtitle)|\(Self.finishBody)|c=turn-complete;p=0",
            ])
        }

        /// Ends the pane's turn and returns its finish alert as recorded.
        @discardableResult
        func finishTurn(_ pane: UUID) async throws -> TerminalNotification {
            try await sendStop(pane)
            return try XCTUnwrap(notifications(pane).first, "Precondition: the finish alert was recorded")
        }

        /// What the Claude Notification hook sends for `idle_prompt`.
        func reminder(_ pane: UUID) -> String {
            "notify_target_async \(workspaceId.uuidString) \(pane.uuidString) Claude Code|\(Self.reminderSubtitle)|Claude is waiting for your input|c=idle-reminder;p=0"
        }

        /// What the prompt-submit and pre-tool-use hooks send for a pane.
        func turnStart(_ pane: UUID) -> [String] {
            ["clear_notifications --tab=\(workspaceId.uuidString) --panel=\(pane.uuidString)", lifecycle(pane, "running")]
        }

        /// A clear of every pane in the workspace from another socket client
        /// (`cmux clear-notifications --workspace`, or an older CLI's hook).
        var workspaceWideClear: String {
            "clear_notifications --tab=\(workspaceId.uuidString)"
        }

        func lifecycle(_ pane: UUID, _ state: String) -> String {
            "set_agent_lifecycle claude_code \(state) --tab=\(workspaceId.uuidString) --panel=\(pane.uuidString)"
        }

        func notifications(_ pane: UUID) -> [TerminalNotification] {
            store.notifications.filter { $0.tabId == workspaceId && $0.surfaceId == pane }
        }

        private static func restore(_ value: Any?, forKey key: String) {
            if let value {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
    }

    private func makeSocketPath(_ name: String) -> String {
        let shortID = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(8)
        return URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tnq-\(name.prefix(4))-\(shortID).sock")
            .path
    }

    private func waitForSocket(at path: String, timeout: TimeInterval = 5.0) throws {
        let expectation = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in
                FileManager.default.fileExists(atPath: path)
            },
            object: NSObject()
        )
        if XCTWaiter().wait(for: [expectation], timeout: timeout) == .completed {
            return
        }
        XCTFail("Timed out waiting for socket at \(path)")
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(ETIMEDOUT))
    }

    private nonisolated func sendCommands(_ commands: [String], to socketPath: String) throws -> [String] {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw posixError("socket(AF_UNIX)")
        }
        defer { Darwin.close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)

        let bytes = Array(socketPath.utf8)
        let maxPathLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard bytes.count < maxPathLen else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENAMETOOLONG))
        }

        withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
            let cPath = UnsafeMutableRawPointer(pathPtr).assumingMemoryBound(to: CChar.self)
            cPath.initialize(repeating: 0, count: maxPathLen)
            for (index, byte) in bytes.enumerated() {
                cPath[index] = CChar(bitPattern: byte)
            }
        }

        let addrLen = socklen_t(MemoryLayout<sa_family_t>.size + bytes.count + 1)
        let connectResult = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                Darwin.connect(fd, sockaddrPtr, addrLen)
            }
        }
        guard connectResult == 0 else {
            throw posixError("connect(\(socketPath))")
        }

        var responses: [String] = []
        for command in commands {
            try writeLine(command, to: fd)
            responses.append(try readLine(from: fd))
        }
        return responses
    }

    private nonisolated func writeLine(_ command: String, to fd: Int32) throws {
        let payload = Array((command + "\n").utf8)
        var offset = 0
        while offset < payload.count {
            let wrote = payload.withUnsafeBytes { raw in
                Darwin.write(fd, raw.baseAddress!.advanced(by: offset), payload.count - offset)
            }
            guard wrote >= 0 else {
                throw posixError("write(\(command))")
            }
            offset += wrote
        }
    }

    private nonisolated func readLine(from fd: Int32) throws -> String {
        var buffer = [UInt8](repeating: 0, count: 1)
        var data = Data()

        while true {
            let count = Darwin.read(fd, &buffer, 1)
            guard count >= 0 else {
                throw posixError("read")
            }
            if count == 0 { break }
            if buffer[0] == 0x0A { break }
            data.append(buffer[0])
        }

        guard let line = String(data: data, encoding: .utf8) else {
            throw NSError(domain: NSCocoaErrorDomain, code: 0, userInfo: [
                NSLocalizedDescriptionKey: "Invalid UTF-8 response from socket"
            ])
        }
        return line
    }

    private nonisolated func posixError(_ operation: String) -> NSError {
        NSError(
            domain: NSPOSIXErrorDomain,
            code: Int(errno),
            userInfo: [NSLocalizedDescriptionKey: "\(operation) failed: \(String(cString: strerror(errno)))"]
        )
    }
}
