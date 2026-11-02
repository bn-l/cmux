import Foundation

extension Workspace {
    /// Returns the authoritative portal-rendering state for a workspace id.
    ///
    /// Portal registries can outlive the SwiftUI representable that created an
    /// entry. They use this query at every bind/visibility boundary so queued
    /// callbacks cannot make an inactive workspace visible again.
    ///
    /// Fork deviation from upstream #12414: a workspace no tab manager knows
    /// (none yet, mid-move, a test fixture) does not hide its portals. Only a
    /// known workspace that is unselected or has rendering disabled denies
    /// presentation; an invisible live terminal is worse than a ghost layer.
    @MainActor
    static func portalRenderingEnabled(for workspaceID: UUID?) -> Bool {
        guard let workspaceID,
              let manager = AppDelegate.shared?.tabManagerFor(tabId: workspaceID),
              let workspace = manager.tabs.first(where: { $0.id == workspaceID }) else {
            return true
        }
        return manager.selectedTabId == workspaceID && workspace.isPortalRenderingEnabled
    }
}
