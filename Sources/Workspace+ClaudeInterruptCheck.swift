import CmuxSidebar
import Foundation

extension Workspace {
    static let claudeInterruptStatusKey = "claude_code"
    /// Long enough for Claude Code to abort the turn and append the sentinel.
    static let claudeInterruptCheckDelay: Duration = .milliseconds(1500)

    /// Esc or Ctrl+C reached a pane whose Claude turn is open (running, or
    /// waiting on a permission prompt that Esc rejects). Queues ONE delayed
    /// transcript check for the pane: presses while it is pending are no-ops,
    /// and a hook-reported lifecycle for the pane before it applies (a new
    /// prompt, a tool call) cancels it. Returns the queued check, or nil when
    /// nothing was queued.
    @discardableResult
    func noteClaudeInterruptKey(
        panelId: UUID,
        delay: Duration = Workspace.claudeInterruptCheckDelay,
        turnWasInterrupted: @escaping @Sendable (UUID) async -> Bool = {
            await ClaudeInterruptCheck.panelTurnWasInterrupted(panelId: $0)
        }
    ) -> Task<Void, Never>? {
        guard claudeTurnIsOpen(panelId: panelId),
              pendingClaudeInterruptCheckTokens[panelId] == nil else {
            return nil
        }
        let token = UUID()
        pendingClaudeInterruptCheckTokens[panelId] = token
        return Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard self?.pendingClaudeInterruptCheckTokens[panelId] == token else { return }
            let interrupted = await turnWasInterrupted(panelId)
            guard let self, pendingClaudeInterruptCheckTokens[panelId] == token else { return }
            pendingClaudeInterruptCheckTokens[panelId] = nil
            guard interrupted, claudeTurnIsOpen(panelId: panelId) else { return }
            markClaudeTurnInterrupted(panelId: panelId)
        }
    }

    /// A Claude hook reported this pane's lifecycle. The hook's word supersedes
    /// a queued Esc/Ctrl+C inference, even when the value is unchanged (a new
    /// prompt re-asserts `.running`). Called only from the hook socket path, so
    /// app-side writes such as the feed concluding a rejected permission
    /// request do not cancel the check that request's Esc queued.
    func supersedeClaudeInterruptCheck(key: String, panelId: UUID?) {
        guard key == Self.claudeInterruptStatusKey, let panelId = panelId ?? focusedPanelId else { return }
        pendingClaudeInterruptCheckTokens[panelId] = nil
    }

    private func claudeTurnIsOpen(panelId: UUID) -> Bool {
        switch agentLifecycleStatesByPanelId[panelId]?[Self.claudeInterruptStatusKey] {
        case .running, .needsInput: true
        case .idle, .unknown, nil: false
        }
    }

    /// Mirrors what the Stop hook publishes for a finished turn, minus the
    /// completion notification (the user ended this turn themselves). The
    /// status pill is workspace-wide, so it is left alone while another pane's
    /// Claude turn is still open.
    private func markClaudeTurnInterrupted(panelId: UUID) {
        let key = Self.claudeInterruptStatusKey
        setAgentLifecycle(key: key, panelId: panelId, lifecycle: .idle)
        guard !agentLifecycleStatesByPanelId.keys.contains(where: claudeTurnIsOpen(panelId:)) else { return }
        statusEntries[key] = SidebarStatusEntry(
            key: key,
            value: String(localized: "agent.generic.notification.status.idle", defaultValue: "Idle"),
            icon: "pause.circle.fill",
            color: "#8E8E93"
        )
    }
}
