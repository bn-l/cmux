public import Foundation

/// A terminal panel whose agent is blocked on the user right now (permission
/// prompt, question, or error), as reported by the agent hooks' live lifecycle
/// state. Unlike a notification it is not consumed by being viewed: it stays
/// until the agent reports another state.
public struct AgentNeedsInputSnapshot: Sendable, Equatable {
    /// The id of the workspace (tab) that owns the panel.
    public let tabId: UUID
    /// The terminal panel the agent runs in (also its surface id).
    public let panelId: UUID
    /// When the panel entered the needs-input state.
    public let since: Date

    /// Creates a needs-input snapshot.
    public init(tabId: UUID, panelId: UUID, since: Date) {
        self.tabId = tabId
        self.panelId = panelId
        self.since = since
    }
}

/// Read seam over the app's per-panel agent lifecycle state, scoped to what the
/// attention jump needs: every panel, in every window, whose agent currently
/// needs input.
@MainActor
public protocol AgentAttentionReading: AnyObject {
    /// Panels whose agent currently needs input, in no particular order.
    var agentsNeedingInput: [AgentNeedsInputSnapshot] { get }
}
