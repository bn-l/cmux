import Foundation

nonisolated struct SurfaceResumeBindingIndex: Sendable {
    static let empty = SurfaceResumeBindingIndex(bindingsByPanel: [:])

    typealias PanelKey = RestorableAgentSessionIndex.PanelKey

    private let bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]
    /// Every workspace's binding for a panel id, best candidate first, so the
    /// cross-restart fallback can skip candidates the directory guard rejects.
    private let bindingsByPanelId: [UUID: [SurfaceResumeBindingSnapshot]]

    init(bindingsByPanel: [PanelKey: SurfaceResumeBindingSnapshot]) {
        self.bindingsByPanel = bindingsByPanel
        // Deterministic order for the cross-restart panel-id fallback: newest first, then
        // workspace id, because Dictionary iteration order varies per launch and an
        // arbitrary winner makes restore non-reproducible.
        var bindingsByPanelId: [UUID: [(workspaceId: UUID, binding: SurfaceResumeBindingSnapshot)]] = [:]
        for (key, binding) in bindingsByPanel {
            bindingsByPanelId[key.panelId, default: []].append((key.workspaceId, binding))
        }
        self.bindingsByPanelId = bindingsByPanelId.mapValues { candidates in
            candidates.sorted(by: Self.panelIdFallbackOutranks).map(\.binding)
        }
    }

    private static func panelIdFallbackOutranks(
        _ lhs: (workspaceId: UUID, binding: SurfaceResumeBindingSnapshot),
        _ rhs: (workspaceId: UUID, binding: SurfaceResumeBindingSnapshot)
    ) -> Bool {
        if lhs.binding.updatedAt != rhs.binding.updatedAt {
            return lhs.binding.updatedAt > rhs.binding.updatedAt
        }
        return lhs.workspaceId.uuidString < rhs.workspaceId.uuidString
    }

    /// The binding recorded for this exact `(workspaceId, panelId)`, or — only when
    /// `directory` proves the panel and the binding share a project tree — the binding
    /// another workspace recorded for the same panel id. See
    /// `AgentSessionDirectoryAffinity` for why the guard exists: workspace ids rotate on
    /// every launch, so after a restart this fallback is the ONLY path that resolves, and
    /// ungated it hands one project's resume command to another project's pane.
    func binding(workspaceId: UUID, panelId: UUID, directory: String?) -> SurfaceResumeBindingSnapshot? {
        if let exact = bindingsByPanel[PanelKey(workspaceId: workspaceId, panelId: panelId)] {
            return exact
        }
        return bindingsByPanelId[panelId]?.first {
            AgentSessionDirectoryAffinity.isAffine($0.cwd, directory)
        }
    }

    static func loadProcessDetectedBindingsSynchronously(
        fileManager: FileManager = .default
    ) -> SurfaceResumeBindingIndex {
        let detectedBindings = processDetectedTmuxBindings(fileManager: fileManager)
        return SurfaceResumeBindingIndex(bindingsByPanel: detectedBindings.mapValues(\.binding))
    }

    static func loadIncludingProcessDetectedBindings(
        fileManager: FileManager = .default
    ) async -> SurfaceResumeBindingIndex {
        await Task.detached(priority: .utility) {
            loadProcessDetectedBindingsSynchronously(fileManager: fileManager)
        }.value
    }
}
