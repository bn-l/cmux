import Foundation

extension Workspace {
    func forkAgentConversationContextMenuAvailability(
        forPanelId panelId: UUID
    ) -> WorkspaceForkAgentConversationAvailability {
        guard panels[panelId] is TerminalPanel else { return .notTerminalPanel }
        guard let snapshot = forkAgentConversationContextMenuCandidateSnapshot(forPanelId: panelId) else {
            return .noAgentSnapshot
        }
        switch ContentView.commandPaletteSnapshotForkAvailability(
            snapshot,
            isRemoteTerminal: isRemoteTerminalSurface(panelId)
        ) {
        case .supportedWithoutProbe:
            return .available
        case .requiresProbe:
            return .requiresProbe
        case .unsupported:
            return .unsupported
        }
    }

    func forkAgentConversationContextMenuOpenAvailability(
        forPanelId panelId: UUID
    ) -> WorkspaceForkAgentConversationAvailability {
        guard panels[panelId] is TerminalPanel else { return .notTerminalPanel }
        if restoredAgentSnapshotForContinuation(panelId: panelId) == nil {
            guard SharedLiveAgentIndex.shared.prepareForkAvailabilityProbe(
                workspaceId: id,
                panelId: panelId,
                directory: agentSessionAffinityDirectory(panelId: panelId)
            ) else {
                return .agentIndexRefreshing
            }
        }
        return forkAgentConversationContextMenuAvailability(forPanelId: panelId)
    }

    private func forkAgentConversationContextMenuCandidateSnapshot(
        forPanelId panelId: UUID
    ) -> SessionRestorableAgentSnapshot? {
        if let snapshot = restoredAgentSnapshotForContinuation(panelId: panelId) {
            return snapshot
        }
        let affinityDirectory = agentSessionAffinityDirectory(panelId: panelId)
        guard let snapshot = SharedLiveAgentIndex.shared.snapshotForForkConversationCandidate(
            workspaceId: id,
            panelId: panelId,
            directory: affinityDirectory
        ) else {
            return nil
        }
        if let observation = SharedLiveAgentIndex.shared.index?.entry(
            workspaceId: id,
            panelId: panelId,
            directory: affinityDirectory
        ) {
            reconcileCompletedRestoredAgent(panelId: panelId, observation: observation)
        }
        return allowsAgentContinuation(forPanelId: panelId) ? snapshot : nil
    }
}
