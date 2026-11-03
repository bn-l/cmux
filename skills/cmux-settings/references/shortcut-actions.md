# Keyboard shortcut action ids

Every id in `docs/cmux.schema.json` (`$defs.shortcutActionId`), grouped by area. `CmuxConfigSchemaDriftTests` keeps that list equal to the app's shortcut actions.

Values for `shortcuts.bindings.<action>`:

- A string like `"cmd+b"` for a single shortcut.
- A two-element array like `["ctrl+b","c"]` for a chord.
- `null`, `[]`, or an empty string (`""`, `"none"`, `"clear"`, `"unbound"`, `"disabled"`) to unbind.
- An object `{ "first": {...}, "second": {...} }`, the form the Settings window writes.

## App

- `shortcuts.bindings.openSettings`
- `shortcuts.bindings.reloadConfiguration`
- `shortcuts.bindings.showHideAllWindows`
- `shortcuts.bindings.globalSearch`
- `shortcuts.bindings.newWindow`
- `shortcuts.bindings.closeWindow`
- `shortcuts.bindings.toggleFullScreen`
- `shortcuts.bindings.quit`
- `shortcuts.bindings.openFolder`
- `shortcuts.bindings.sendFeedback`

## Tabs

- `shortcuts.bindings.newTab`
- `shortcuts.bindings.newBrowserWorkspace`
- `shortcuts.bindings.reopenPreviousSession`
- `shortcuts.bindings.renameTab`
- `shortcuts.bindings.closeTab`
- `shortcuts.bindings.closeOtherTabsInPane`

## Workspace

- `shortcuts.bindings.goToWorkspace`
- `shortcuts.bindings.selectWorkspaceByNumber`
- `shortcuts.bindings.renameWorkspace`
- `shortcuts.bindings.editWorkspaceDescription`
- `shortcuts.bindings.closeWorkspace`
- `shortcuts.bindings.newWorkspaceGroup`
- `shortcuts.bindings.groupSelectedWorkspaces`
- `shortcuts.bindings.toggleFocusedWorkspaceGroupCollapsed`
- `shortcuts.bindings.saveLayoutTemplate`
- `shortcuts.bindings.reopenClosedWorkspace`
- `shortcuts.bindings.focusHistoryBack`
- `shortcuts.bindings.focusHistoryForward`
- `shortcuts.bindings.focusHistoryLast` (no default: toggles between the two most recent focus positions)

## Panes and surfaces

- `shortcuts.bindings.nextSurface`
- `shortcuts.bindings.prevSurface`
- `shortcuts.bindings.selectSurfaceByNumber`
- `shortcuts.bindings.newSurface`
- `shortcuts.bindings.toggleTerminalCopyMode`
- `shortcuts.bindings.clearScreenKeepScrollback`
- `shortcuts.bindings.sendCtrlFToTerminal`
- `shortcuts.bindings.focusLeft`
- `shortcuts.bindings.focusRight`
- `shortcuts.bindings.focusUp`
- `shortcuts.bindings.focusDown`
- `shortcuts.bindings.splitRight`
- `shortcuts.bindings.splitDown`
- `shortcuts.bindings.toggleSplitZoom`
- `shortcuts.bindings.equalizeSplits`
- `shortcuts.bindings.resize-pane-left` (default Ctrl+Shift+H)
- `shortcuts.bindings.resize-pane-right` (default Ctrl+Shift+L)
- `shortcuts.bindings.resize-pane-up` (default Ctrl+Shift+K)
- `shortcuts.bindings.resize-pane-down` (default Ctrl+Shift+J)

## Text box

- `shortcuts.bindings.focusTextBoxInput`
- `shortcuts.bindings.cycleTextBoxSubmitAction` (single stroke only, no chords)
- `shortcuts.bindings.attachTextBoxFile`

## Canvas

- `shortcuts.bindings.toggleCanvasLayout`
- `shortcuts.bindings.canvasRevealFocusedPane`
- `shortcuts.bindings.canvasOverview`
- `shortcuts.bindings.canvasZoomIn`
- `shortcuts.bindings.canvasZoomOut`
- `shortcuts.bindings.canvasZoomReset`
- `shortcuts.bindings.canvasTidy`
- `shortcuts.bindings.canvasAlignLeft`
- `shortcuts.bindings.canvasAlignRight`
- `shortcuts.bindings.canvasAlignTop`
- `shortcuts.bindings.canvasAlignBottom`
- `shortcuts.bindings.canvasEqualizeWidths`
- `shortcuts.bindings.canvasEqualizeHeights`
- `shortcuts.bindings.canvasDistributeHorizontally`
- `shortcuts.bindings.canvasDistributeVertically`

## Command palette

- `shortcuts.bindings.commandPalette`
- `shortcuts.bindings.commandPaletteNext`
- `shortcuts.bindings.commandPalettePrevious`

## Notifications

- `shortcuts.bindings.showNotifications`
- `shortcuts.bindings.jumpToUnread`
- `shortcuts.bindings.jumpToLastPrompt`
- `shortcuts.bindings.toggleUnread`
- `shortcuts.bindings.markOldestUnreadAndJumpNext`
- `shortcuts.bindings.triggerFlash`

## Sidebar

- `shortcuts.bindings.toggleSidebar`
- `shortcuts.bindings.nextSidebarTab`
- `shortcuts.bindings.prevSidebarTab`

## Browser

- `shortcuts.bindings.reopenClosedBrowserPanel`
- `shortcuts.bindings.splitBrowserRight`
- `shortcuts.bindings.splitBrowserDown`
- `shortcuts.bindings.openBrowser`
- `shortcuts.bindings.focusBrowserAddressBar`
- `shortcuts.bindings.browserBack`
- `shortcuts.bindings.browserForward`
- `shortcuts.bindings.browserReload`
- `shortcuts.bindings.browserHardReload`
- `shortcuts.bindings.browserZoomIn`
- `shortcuts.bindings.browserZoomOut`
- `shortcuts.bindings.browserZoomReset`
- `shortcuts.bindings.toggleBrowserDeveloperTools`
- `shortcuts.bindings.showBrowserJavaScriptConsole`
- `shortcuts.bindings.toggleBrowserFocusMode`

## Find

- `shortcuts.bindings.find`
- `shortcuts.bindings.findNext`
- `shortcuts.bindings.findPrevious`
- `shortcuts.bindings.hideFind`
- `shortcuts.bindings.useSelectionForFind`

## File preview and React Grab

- `shortcuts.bindings.saveFilePreview`
- `shortcuts.bindings.toggleReactGrab`

## Markdown viewer

- `shortcuts.bindings.markdownZoomIn`
- `shortcuts.bindings.markdownZoomOut`
- `shortcuts.bindings.markdownZoomReset`

## Diff viewer

The five diff-viewer scroll and search actions may be bound to a bare key with no modifier.

- `shortcuts.bindings.openDiffViewer`
- `shortcuts.bindings.diffViewerScrollDown`
- `shortcuts.bindings.diffViewerScrollUp`
- `shortcuts.bindings.diffViewerScrollToBottom`
- `shortcuts.bindings.diffViewerScrollToTop`
- `shortcuts.bindings.diffViewerOpenFileSearch`
