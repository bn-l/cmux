import Foundation

@MainActor
extension GhosttySurfaceScrollView {
    var notificationScrollPosition: TerminalNotificationScrollPosition? {
        guard let scrollbar = surfaceView.scrollbar else { return nil }
        let rowFromBottom = max(0, scrollbar.total - scrollbar.offset - scrollbar.len)
        return TerminalNotificationScrollPosition(
            row: Int(clamping: rowFromBottom),
            totalRows: Int(clamping: scrollbar.total)
        )
    }

    @discardableResult
    func restoreNotificationScrollPosition(_ position: TerminalNotificationScrollPosition?) -> Bool {
        guard let position else { return false }
        guard let scrollbar = surfaceView.scrollbar else { return false }
        let currentTotalRows = Int(clamping: scrollbar.total)
        let capturedTotalRows = position.totalRows ?? currentTotalRows
        let rowFromBottom = max(0, position.row + currentTotalRows - capturedTotalRows)
        allowExplicitScrollbarSync = true
        userScrolledAwayFromBottom = rowFromBottom > 0
        // `scroll_to_row` is absolute from the top of scrollback (0 is the oldest row),
        // while the captured position is measured from the bottom.
        let rowFromTop = GhosttyTerminalScrollGeometry.topOriginRow(
            rowFromBottom: rowFromBottom,
            totalRows: currentTotalRows,
            viewportRows: Int(clamping: scrollbar.len)
        )
        let didRestore = surfaceView.performBindingAction("scroll_to_row:\(rowFromTop)")
        if !didRestore {
            allowExplicitScrollbarSync = false
        }
        return didRestore
    }
}
