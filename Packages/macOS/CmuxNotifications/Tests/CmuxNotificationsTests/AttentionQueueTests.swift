import Foundation
import Testing
@testable import CmuxNotifications

/// Seconds since an arbitrary epoch, so the expected order is readable.
private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: seconds) }

private func notification(
    tab: UUID,
    surface: UUID? = nil,
    panel: UUID? = nil,
    read: Bool = false,
    created: TimeInterval,
    deferred: TimeInterval? = nil,
    clickAction: NotificationNavClickAction? = nil
) -> NotificationNavSnapshot {
    NotificationNavSnapshot(
        id: UUID(),
        tabId: tab,
        surfaceId: surface,
        panelId: panel,
        isRead: read,
        clickAction: clickAction,
        createdAt: at(created),
        deferredAt: deferred.map(at)
    )
}

private func blocked(tab: UUID, panel: UUID, since: TimeInterval) -> AgentNeedsInputSnapshot {
    AgentNeedsInputSnapshot(tabId: tab, panelId: panel, since: at(since))
}

@Suite("Attention queue order")
struct AttentionQueueTests {
    let tab = UUID()

    // MARK: Order

    @Test("agents that need input come first, then unread notifications, each oldest first")
    func urgencyThenOldestFirst() {
        let (p1, p2, p3, p4) = (UUID(), UUID(), UUID(), UUID())
        // Store order is newest first, the opposite of the expected visit order.
        let newUnread = notification(tab: tab, surface: p1, created: 400)
        let oldUnread = notification(tab: tab, surface: p2, created: 100)

        let entries = AttentionQueue.entries(
            notifications: [newUnread, oldUnread],
            agentsNeedingInput: [
                blocked(tab: tab, panel: p3, since: 500),
                blocked(tab: tab, panel: p4, since: 300),
            ]
        )

        #expect(entries.map(\.surfaceId) == [p4, p3, p2, p1])
        #expect(entries.map(\.kind) == [.needsInput, .needsInput, .unread, .unread])
    }

    @Test("a blocked panel with an unread notification is one entry that opens the notification, timed from the block")
    func blockedPanelMergesWithItsUnreadNotification() {
        let panel = UUID()
        let unread = notification(tab: tab, surface: panel, created: 50)

        let entries = AttentionQueue.entries(
            notifications: [unread],
            agentsNeedingInput: [blocked(tab: tab, panel: panel, since: 80)]
        )

        #expect(entries.count == 1)
        #expect(entries.first?.notification?.id == unread.id)
        #expect(entries.first?.kind == .needsInput)
        #expect(entries.first?.since == at(80))
    }

    @Test("a notification recorded against the panel id (not the surface id) still merges with the blocked agent")
    func mergesByPanelIdWhenSurfaceDiffers() {
        let panel = UUID()
        let unread = notification(tab: tab, surface: UUID(), panel: panel, created: 50)

        let entries = AttentionQueue.entries(
            notifications: [unread],
            agentsNeedingInput: [blocked(tab: tab, panel: panel, since: 80)]
        )

        #expect(entries.count == 1)
        #expect(entries.first?.kind == .needsInput)
    }

    @Test("the same panel id in another workspace does not merge")
    func panelMatchIsScopedToItsWorkspace() {
        let panel = UUID()
        let unread = notification(tab: UUID(), surface: panel, created: 50)

        let entries = AttentionQueue.entries(
            notifications: [unread],
            agentsNeedingInput: [blocked(tab: tab, panel: panel, since: 80)]
        )

        #expect(entries.map(\.kind) == [.needsInput, .unread])
    }

    @Test("a blocked panel whose notification was read is still an entry, without a notification to open")
    func blockedPanelWithReadNotificationStays() {
        let panel = UUID()

        let entries = AttentionQueue.entries(
            notifications: [notification(tab: tab, surface: panel, read: true, created: 50)],
            agentsNeedingInput: [blocked(tab: tab, panel: panel, since: 40)]
        )

        #expect(entries.count == 1)
        #expect(entries.first?.notification == nil)
        #expect(entries.first?.surfaceId == panel)
    }

    @Test("read notifications and click-action notifications are not entries")
    func readAndClickActionNotificationsAreSkipped() {
        let entries = AttentionQueue.entries(
            notifications: [
                notification(tab: tab, surface: UUID(), read: true, created: 1),
                notification(tab: tab, created: 2, clickAction: .revealInFinder(path: "/tmp/crash")),
            ],
            agentsNeedingInput: []
        )

        #expect(entries.isEmpty)
    }

    @Test("a workspace-level notification never merges with a panel's blocked agent")
    func workspaceLevelNotificationStaysSeparate() {
        let panel = UUID()

        let entries = AttentionQueue.entries(
            notifications: [notification(tab: tab, surface: nil, created: 10)],
            agentsNeedingInput: [blocked(tab: tab, panel: panel, since: 20)]
        )

        #expect(entries.map(\.surfaceId) == [panel, nil])
    }

    @Test("entries with identical timestamps keep the input order")
    func tiesKeepInputOrder() {
        let (p1, p2, p3) = (UUID(), UUID(), UUID())

        let entries = AttentionQueue.entries(
            notifications: [
                notification(tab: tab, surface: p1, created: 5),
                notification(tab: tab, surface: p2, created: 5),
                notification(tab: tab, surface: p3, created: 5),
            ],
            agentsNeedingInput: []
        )

        #expect(entries.map(\.surfaceId) == [p1, p2, p3])
    }

    // MARK: Send to back ("mark as oldest unread")

    @Test("deferred entries go after every non-deferred entry, earliest deferral first")
    func deferredEntriesGoLast() {
        let (p1, p2, p3, p4) = (UUID(), UUID(), UUID(), UUID())

        let entries = AttentionQueue.entries(
            notifications: [
                notification(tab: tab, surface: p1, created: 1, deferred: 900),
                notification(tab: tab, surface: p2, created: 2, deferred: 800),
                notification(tab: tab, surface: p3, created: 999),
                notification(tab: tab, surface: p4, created: 3),
            ],
            agentsNeedingInput: []
        )

        #expect(entries.map(\.surfaceId) == [p4, p3, p2, p1])
    }

    @Test("a deferred blocked agent goes after a non-deferred unread notification")
    func deferralOutranksUrgency() {
        let (blockedPanel, unreadPanel) = (UUID(), UUID())

        let entries = AttentionQueue.entries(
            notifications: [
                notification(tab: tab, surface: blockedPanel, read: true, created: 10, deferred: 30),
                notification(tab: tab, surface: unreadPanel, created: 40),
            ],
            agentsNeedingInput: [blocked(tab: tab, panel: blockedPanel, since: 20)]
        )

        #expect(entries.map(\.surfaceId) == [unreadPanel, blockedPanel])
    }

    @Test("a deferral made before the current block does not bury the new block")
    func staleDeferralIsIgnoredForNewBlock() {
        let (blockedPanel, unreadPanel) = (UUID(), UUID())

        let readEntries = AttentionQueue.entries(
            notifications: [
                notification(tab: tab, surface: blockedPanel, read: true, created: 10, deferred: 15),
                notification(tab: tab, surface: unreadPanel, created: 40),
            ],
            agentsNeedingInput: [blocked(tab: tab, panel: blockedPanel, since: 20)]
        )
        let unreadEntries = AttentionQueue.entries(
            notifications: [
                notification(tab: tab, surface: blockedPanel, created: 10, deferred: 15),
                notification(tab: tab, surface: unreadPanel, created: 40),
            ],
            agentsNeedingInput: [blocked(tab: tab, panel: blockedPanel, since: 20)]
        )

        #expect(readEntries.map(\.surfaceId) == [blockedPanel, unreadPanel])
        #expect(readEntries.first?.deferredAt == nil)
        #expect(unreadEntries.map(\.surfaceId) == [blockedPanel, unreadPanel])
        #expect(unreadEntries.first?.deferredAt == nil)
    }

    @Test("a deferred unread notification stays deferred when no agent is blocked")
    func deferralOfPlainUnreadIsKept() {
        let entries = AttentionQueue.entries(
            notifications: [notification(tab: tab, surface: UUID(), created: 10, deferred: 5)],
            agentsNeedingInput: []
        )

        #expect(entries.first?.deferredAt == at(5))
    }

    // MARK: Exclusion

    @Test("excluding a notification also removes its panel's blocked-agent entry, but not other panels")
    func excludedNotificationRemovesItsPanel() {
        let (deferredPanel, otherPanel) = (UUID(), UUID())
        let excluded = notification(tab: tab, surface: deferredPanel, read: false, created: 1)

        let entries = AttentionQueue.entries(
            notifications: [excluded],
            agentsNeedingInput: [
                blocked(tab: tab, panel: deferredPanel, since: 2),
                blocked(tab: tab, panel: otherPanel, since: 3),
            ],
            excludingNotificationId: excluded.id
        )

        #expect(entries.map(\.surfaceId) == [otherPanel])
    }

    @Test("excluding a workspace removes its notifications and its blocked agents")
    func excludedWorkspaceRemovesEverythingInIt() {
        let otherTab = UUID()
        let kept = notification(tab: otherTab, surface: UUID(), created: 9)

        let entries = AttentionQueue.entries(
            notifications: [notification(tab: tab, surface: UUID(), created: 1), kept],
            agentsNeedingInput: [blocked(tab: tab, panel: UUID(), since: 2)],
            excludingWorkspaceId: tab
        )

        #expect(entries.map(\.notification?.id) == [kept.id])
    }

    @Test("an exclusion id that matches no notification excludes nothing")
    func unknownExclusionIsHarmless() {
        let entries = AttentionQueue.entries(
            notifications: [notification(tab: tab, surface: UUID(), created: 1)],
            agentsNeedingInput: [blocked(tab: tab, panel: UUID(), since: 2)],
            excludingNotificationId: UUID()
        )

        #expect(entries.count == 2)
    }

    // MARK: Visit order relative to focus

    @Test("with nothing focused, or a focused panel outside the queue, the visit starts at the first entry")
    func visitStartsAtFirstWhenFocusIsOutsideQueue() {
        let entries = AttentionQueue.entries(
            notifications: [],
            agentsNeedingInput: [blocked(tab: tab, panel: UUID(), since: 1), blocked(tab: tab, panel: UUID(), since: 2)]
        )
        let outside = FocusedNotificationTarget(tabId: tab, surfaceId: UUID())

        #expect(AttentionQueue.visitOrder(after: nil, in: entries) == entries)
        #expect(AttentionQueue.visitOrder(after: outside, in: entries) == entries)
    }

    @Test("a focused entry is skipped and the visit wraps around past it")
    func visitWrapsPastFocusedEntry() {
        let (p1, p2, p3) = (UUID(), UUID(), UUID())
        let entries = AttentionQueue.entries(
            notifications: [],
            agentsNeedingInput: [
                blocked(tab: tab, panel: p1, since: 1),
                blocked(tab: tab, panel: p2, since: 2),
                blocked(tab: tab, panel: p3, since: 3),
            ]
        )

        let fromMiddle = AttentionQueue.visitOrder(after: FocusedNotificationTarget(tabId: tab, surfaceId: p2), in: entries)
        let fromLast = AttentionQueue.visitOrder(after: FocusedNotificationTarget(tabId: tab, surfaceId: p3), in: entries)

        #expect(fromMiddle.map(\.surfaceId) == [p3, p1])
        #expect(fromLast.map(\.surfaceId) == [p1, p2])
    }

    @Test("when the focused panel is the only entry there is nothing to visit")
    func onlyFocusedEntryYieldsNothing() {
        let panel = UUID()
        let entries = AttentionQueue.entries(notifications: [], agentsNeedingInput: [blocked(tab: tab, panel: panel, since: 1)])

        #expect(AttentionQueue.visitOrder(after: FocusedNotificationTarget(tabId: tab, surfaceId: panel), in: entries).isEmpty)
    }

    @Test("focus matching needs the same workspace: the same panel id elsewhere is not the focused entry")
    func focusMatchRequiresSameWorkspace() {
        let panel = UUID()
        let entries = AttentionQueue.entries(notifications: [], agentsNeedingInput: [blocked(tab: tab, panel: panel, since: 1)])

        let visit = AttentionQueue.visitOrder(after: FocusedNotificationTarget(tabId: UUID(), surfaceId: panel), in: entries)

        #expect(visit == entries)
    }
}
