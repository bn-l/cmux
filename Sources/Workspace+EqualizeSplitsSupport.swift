import Bonsplit
import CmuxPanes
import CmuxSettings
import Foundation

extension Workspace {
    func didProgrammaticallyChangeSplitGeometry() {
        splitTabBar(bonsplitController, didChangeGeometry: bonsplitController.layoutSnapshot())
    }

    /// Rebalances the panes of a newly created split's row or column when
    /// `app.equalizeSplitsOnCreate` is on (upstream manaflow-ai/cmux#14703).
    ///
    /// The shared post-create step for user-initiated splits: TabManager's
    /// terminal and browser splits (shortcut, menu, context menu, command
    /// palette, AppleScript), the v1/v2 socket split commands, and bonsplit's
    /// own split buttons. Session restore and layout builders skip it because
    /// they impose their own divider positions. Only the run of
    /// same-orientation splits that holds the new pane moves, so a vertical
    /// split never disturbs the widths of side-by-side panes, and dividers in
    /// unrelated rows keep their sizes.
    ///
    /// - Returns: `true` when the setting is on and a split was rebalanced.
    @discardableResult
    func equalizeSplitsAfterCreatingSplitIfEnabled(
        newPanelId: UUID,
        settings: any SettingsReading = UserDefaultsSettingsClient(defaults: .standard)
    ) -> Bool {
        guard let newPaneId = paneId(forPanelId: newPanelId) else { return false }
        return equalizeSplitsAfterCreatingSplitIfEnabled(newPaneId: newPaneId, settings: settings)
    }

    @discardableResult
    func equalizeSplitsAfterCreatingSplitIfEnabled(
        newPaneId: PaneID,
        settings: any SettingsReading = UserDefaultsSettingsClient(defaults: .standard)
    ) -> Bool {
        guard settings.value(for: SettingCatalog().app.equalizeSplitsOnCreate),
              layoutMode != .canvas,
              !isRemoteTmuxMirror else { return false }
        let result = PaneLayoutService().equalizeSplitRun(
            containingPaneId: newPaneId.id.uuidString,
            in: bonsplitController.treeSnapshot(),
            controller: bonsplitController
        )
        guard result.foundSplit else { return false }
        // Same follow-up as the Equalize Splits command.
        didProgrammaticallyChangeSplitGeometry()
        return true
    }
}
