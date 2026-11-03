import AppKit
import Foundation

/// When the user last submitted an agent prompt in each panel. Fed by
/// UserPromptSubmit feed events (`TerminalController.v2ApplyIMessageModeSideEffects`),
/// which carry the hook's surface id for every agent in the hook catalog.
/// Keyed by panel so a panel moved to another workspace keeps its entry; in
/// memory only, so right after a relaunch there is nothing to jump to.
@MainActor
final class LastPromptSubmissionLog {
    private(set) var submittedAtByPanelId: [UUID: Date] = [:]

    func record(panelId: UUID, at date: Date) {
        submittedAtByPanelId[panelId] = date
    }

    /// Drops entries for panels that no longer exist anywhere.
    func prune(keeping livePanelIds: Set<UUID>) {
        submittedAtByPanelId = submittedAtByPanelId.filter { livePanelIds.contains($0.key) }
    }
}

/// "Jump to Last Prompt" (upstream manaflow-ai/cmux#18951): focus the surface
/// where the user most recently submitted a prompt to a coding agent, across
/// every workspace and window. The ⌘⇧B shortcut, the View menu item and
/// `surface.jump_to_last_prompt` all go through ``AppDelegate/jumpToLastPrompt()``.
extension AppDelegate {
    /// One live panel with a recorded prompt submit.
    struct LastPromptTarget: Equatable, Sendable {
        let workspaceId: UUID
        let panelId: UUID
        let submittedAt: Date

        /// The most recent submit. Equal timestamps resolve by workspace id,
        /// then panel id, so the choice never depends on dictionary order.
        nonisolated static func newest(in candidates: [LastPromptTarget]) -> LastPromptTarget? {
            candidates.min(by: isNewer)
        }

        /// Every candidate, most recent submit first, in the same order
        /// ``newest(in:)`` picks from.
        nonisolated static func newestFirst(_ candidates: [LastPromptTarget]) -> [LastPromptTarget] {
            candidates.sorted(by: isNewer)
        }

        private nonisolated static func isNewer(_ lhs: LastPromptTarget, than rhs: LastPromptTarget) -> Bool {
            if lhs.submittedAt != rhs.submittedAt { return lhs.submittedAt > rhs.submittedAt }
            if lhs.workspaceId != rhs.workspaceId { return lhs.workspaceId.uuidString < rhs.workspaceId.uuidString }
            return lhs.panelId.uuidString < rhs.panelId.uuidString
        }
    }

    func recordPromptSubmitted(panelId: UUID, at date: Date = Date()) {
        lastPromptSubmissions.record(panelId: panelId, at: date)
    }

    /// Every live panel with a recorded prompt, across all windows, most
    /// recent submit first. Entries for closed panels are dropped.
    func lastPromptTargetsNewestFirst() -> [LastPromptTarget] {
        var workspaceIdByPanelId: [UUID: UUID] = [:]
        for manager in liveWorkspaceIdentityTabManagers() {
            for workspace in manager.tabs {
                for panelId in workspace.panels.keys {
                    workspaceIdByPanelId[panelId] = workspace.id
                }
            }
        }
        lastPromptSubmissions.prune(keeping: Set(workspaceIdByPanelId.keys))
        let candidates = lastPromptSubmissions.submittedAtByPanelId.compactMap { panelId, submittedAt in
            workspaceIdByPanelId[panelId].map {
                LastPromptTarget(workspaceId: $0, panelId: panelId, submittedAt: submittedAt)
            }
        }
        return LastPromptTarget.newestFirst(candidates)
    }

    /// Selects the workspace (and its window) and focuses the surface of the
    /// most recent prompt, the same way opening a notification does. A window
    /// that is briefly detached cannot take focus, so the next most recent
    /// target is tried instead. Returns the target it focused, or nil.
    @discardableResult
    func jumpToLastPrompt() -> LastPromptTarget? {
        lastPromptTargetsNewestFirst().first { target in
            openNotification(tabId: target.workspaceId, surfaceId: target.panelId, notificationId: nil)
        }
    }

    /// Keyboard and menu entry point: beeps when there is nowhere to jump.
    func jumpToLastPromptFromUserCommand() {
        if jumpToLastPrompt() == nil {
            NSSound.beep()
        }
    }
}
