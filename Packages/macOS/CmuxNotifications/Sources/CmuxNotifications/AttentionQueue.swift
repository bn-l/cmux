public import Foundation

/// The order in which the attention jump (⌘⇧U) visits things that need the user.
///
/// An entry is either an agent that needs input right now (its live lifecycle
/// state, which viewing the panel does not clear) or an unread notification (a
/// finished turn, an OSC alert, `cmux notify`, …), merged per panel when both
/// apply. Order:
/// 1. entries the user sent to the back ("mark as oldest unread") come last,
///    oldest deferral first;
/// 2. otherwise agents that need input come before plain unread notifications;
/// 3. within each group the oldest comes first, so an agent blocked for a long
///    time is not starved by newer arrivals.
///
/// Pure value logic: the coordinator feeds it store/lifecycle snapshots and
/// performs the opens.
public enum AttentionQueue {
    /// One thing the jump can visit.
    public struct Entry: Sendable, Equatable {
        /// Why the entry needs the user. Declaration order is visit order.
        public enum Kind: Int, Sendable, Comparable {
            /// The panel's agent is blocked on the user.
            case needsInput
            /// An unread notification whose panel's agent is not blocked.
            case unread

            public static func < (lhs: Kind, rhs: Kind) -> Bool { lhs.rawValue < rhs.rawValue }
        }

        /// The workspace (tab) to select.
        public let tabId: UUID
        /// The panel/surface to focus; `nil` for a workspace-level notification.
        public let surfaceId: UUID?
        /// The unread notification this entry opens (and marks read); `nil` for
        /// an agent that needs input but has no unread notification.
        public let notification: NotificationNavSnapshot?
        /// Why the entry needs the user.
        public let kind: Kind
        /// When the entry started needing the user: the time the agent became
        /// blocked, else the notification's creation time.
        public let since: Date
        /// When the user sent the entry to the back of the queue, if they did.
        public let deferredAt: Date?
    }

    private struct PanelKey: Hashable {
        let tabId: UUID
        let panelId: UUID
    }

    /// Every entry, in visit order.
    ///
    /// - Parameters:
    ///   - notifications: The store's notifications, newest first.
    ///   - agentsNeedingInput: Panels whose agent currently needs input.
    ///   - excludedNotificationId: A notification to leave out, together with
    ///     the needs-input entry of its panel (the one the user just deferred).
    ///   - excludedWorkspaceId: A workspace whose entries are all left out.
    public static func entries(
        notifications: [NotificationNavSnapshot],
        agentsNeedingInput: [AgentNeedsInputSnapshot],
        excludingNotificationId excludedNotificationId: UUID? = nil,
        excludingWorkspaceId excludedWorkspaceId: UUID? = nil
    ) -> [Entry] {
        let excludedNotification = excludedNotificationId.flatMap { id in
            notifications.first { $0.id == id }
        }
        let agents = agentsNeedingInput.filter { agent in
            agent.tabId != excludedWorkspaceId
                && excludedNotification?.belongs(toTabId: agent.tabId, panelId: agent.panelId) != true
        }

        var entries: [Entry] = []
        var panelsWithUnreadNotification = Set<PanelKey>()
        for notification in notifications
        where notification.isOpenableForJump(
            excludingNotificationId: excludedNotificationId,
            excludingWorkspaceId: excludedWorkspaceId
        ) {
            let blockedAgent = agents.first {
                notification.belongs(toTabId: $0.tabId, panelId: $0.panelId)
            }
            if let blockedAgent {
                panelsWithUnreadNotification.insert(PanelKey(tabId: blockedAgent.tabId, panelId: blockedAgent.panelId))
            }
            entries.append(Entry(
                tabId: notification.tabId,
                surfaceId: notification.surfaceId,
                notification: notification,
                kind: blockedAgent == nil ? .unread : .needsInput,
                since: blockedAgent?.since ?? notification.createdAt,
                deferredAt: deferral(notification.deferredAt, during: blockedAgent)
            ))
        }

        for agent in agents
        where !panelsWithUnreadNotification.contains(PanelKey(tabId: agent.tabId, panelId: agent.panelId)) {
            // The panel's already-read latest notification still carries the
            // "send to back" mark.
            let latestNotification = notifications.first {
                $0.belongs(toTabId: agent.tabId, panelId: agent.panelId)
            }
            entries.append(Entry(
                tabId: agent.tabId,
                surfaceId: agent.panelId,
                notification: nil,
                kind: .needsInput,
                since: agent.since,
                deferredAt: deferral(latestNotification?.deferredAt, during: agent)
            ))
        }

        // Ties fall back to input order so the result is deterministic.
        return entries.enumerated()
            .sorted { lhs, rhs in
                precedes(lhs.element, rhs.element) ?? (lhs.offset < rhs.offset)
            }
            .map(\.element)
    }

    /// The entries to try, in order, for the next jump. When the focused panel is
    /// itself an entry the visit starts after it and wraps around, so repeated
    /// jumps cycle through agents that stay blocked; the focused entry is left
    /// out. Otherwise the visit starts at the first entry.
    public static func visitOrder(
        after focused: FocusedNotificationTarget?,
        in entries: [Entry]
    ) -> [Entry] {
        guard let focused,
              let index = entries.firstIndex(where: {
                  $0.tabId == focused.tabId && $0.surfaceId == focused.surfaceId
              }) else {
            return entries
        }
        return Array(entries[(index + 1)...] + entries[..<index])
    }

    /// A deferral counts for a blocked agent only if it was made during the
    /// current block: a deferral from an earlier block must not bury a new one.
    private static func deferral(_ deferredAt: Date?, during blockedAgent: AgentNeedsInputSnapshot?) -> Date? {
        guard let deferredAt, let blockedAgent else { return deferredAt }
        return deferredAt >= blockedAgent.since ? deferredAt : nil
    }

    /// `true`/`false` when `lhs` and `rhs` have a defined order, `nil` on a tie.
    private static func precedes(_ lhs: Entry, _ rhs: Entry) -> Bool? {
        switch (lhs.deferredAt, rhs.deferredAt) {
        case (nil, .some):
            return true
        case (.some, nil):
            return false
        case let (.some(lhsDeferredAt), .some(rhsDeferredAt)):
            return lhsDeferredAt == rhsDeferredAt ? nil : lhsDeferredAt < rhsDeferredAt
        case (nil, nil):
            if lhs.kind != rhs.kind { return lhs.kind < rhs.kind }
            return lhs.since == rhs.since ? nil : lhs.since < rhs.since
        }
    }
}
