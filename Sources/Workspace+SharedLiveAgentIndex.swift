import Foundation

extension Workspace {
    /// Reconciles previously completed restored agents against the fresh index.
    /// Only their lifecycle state changes; this never publishes the workspace.
    /// Upstream #22748: an index reload publishing every workspace re-rendered
    /// every pane, and the Fork Conversation menu asks for availability when it
    /// opens, so nothing needs the publish.
    func handleSharedLiveAgentIndexChange() {
        guard let index = SharedLiveAgentIndex.shared.index else { return }
        let completedPanelIds = restoredAgentResumeStatesByPanelId.compactMap { panelId, state in
            state == .completedAgentExit ? panelId : nil
        }
        for panelId in completedPanelIds {
            guard let observation = index.entry(
                workspaceId: id,
                panelId: panelId,
                directory: agentSessionAffinityDirectory(panelId: panelId)
            ) else {
                continue
            }
            reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
        }
    }
}
