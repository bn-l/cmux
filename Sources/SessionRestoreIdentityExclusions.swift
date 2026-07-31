import Foundation

@MainActor
final class SessionRestoreIdentityExclusions {
    private var excludedStableIds: Set<UUID> = []
    private var previousExclusionStack: [Set<UUID>] = []

    func beginRestore(excluding ids: Set<UUID>) {
        previousExclusionStack.append(excludedStableIds)
        excludedStableIds = ids
    }

    func endRestore() {
        excludedStableIds = previousExclusionStack.popLast() ?? []
    }

    func shouldAdopt(_ id: UUID) -> Bool {
        !excludedStableIds.contains(id)
    }
}

/// Which agent sessions have already been claimed by a pane during one restore pass.
///
/// A quit snapshot can name the same session id on several panes: a hook record poisoned
/// by mis-routing binds a session to a pane that never hosted it, and both that pane and
/// the real one persist the binding. Restoring all of them launches
/// `<agent> --resume <same id>` once per pane. Beyond starting several clients on one
/// conversation, the hook store is keyed by session id and can only point at one pane, so
/// the last SessionStart wins and every other pane's hooks route to the wrong tab —
/// which is written back to the snapshot and replayed, growing each restart.
///
/// One TabManager restore pass installs a single instance across every workspace it
/// rebuilds, so the "first claimant wins" rule holds across workspaces, not just within
/// one. Later claimants restore as a plain shell in their saved directory.
@MainActor
final class SessionRestoreAgentSessionClaims {
    private var claimedKeys: Set<String> = []

    /// Claims `sessionId` for the calling pane. Returns `false` when an earlier pane in
    /// this pass already claimed it, meaning this pane must not resume. A blank session
    /// id is not a claim (nothing to collide on) and is always allowed.
    func claim(kind: String?, sessionId: String?) -> Bool {
        guard let key = Self.claimKey(kind: kind, sessionId: sessionId) else { return true }
        return claimedKeys.insert(key).inserted
    }

    nonisolated static func claimKey(kind: String?, sessionId: String?) -> String? {
        guard let sessionId = sessionId?.trimmingCharacters(in: .whitespacesAndNewlines),
              !sessionId.isEmpty else {
            return nil
        }
        let normalizedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(normalizedKind?.isEmpty == false ? normalizedKind! : "unknown")\u{1f}\(sessionId)"
    }
}
