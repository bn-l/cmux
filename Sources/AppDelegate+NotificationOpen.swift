import AppKit
import CmuxSettings
import Foundation

/// The window and workspace a notification open focused.
struct NotificationOpenLanding {
    weak var window: NSWindow?
    weak var tabManager: TabManager?
    let workspaceId: UUID
}

@MainActor
extension AppDelegate {
    /// Flashes the landing workspace's name over its window when the jump that
    /// just ran (see ``lastNotificationOpenLanding``) left `originWorkspaceId`.
    func flashWorkspaceNameIfJumpChangedWorkspace(from originWorkspaceId: UUID?) {
        guard let landing = lastNotificationOpenLanding else { return }
        lastNotificationOpenLanding = nil
        guard landing.workspaceId != originWorkspaceId,
              UserDefaultsSettingsClient(defaults: .standard).value(for: SettingCatalog().notifications.jumpShowsWorkspaceName),
              let window = landing.window,
              let tabManager = landing.tabManager,
              let workspace = tabManager.workspacesById[landing.workspaceId] else { return }
        let title = tabManager.resolvedWorkspaceDisplayTitle(for: workspace).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        WorkspaceNameFlashOverlayController.controller(for: window).show(
            title: title,
            colorHex: tabManager.resolvedWorkspaceIndicatorColorHex(for: workspace)
        )
    }

    @discardableResult
    func openNotification(
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        notificationId: UUID?,
        scrollPosition: TerminalNotificationScrollPosition? = nil
    ) -> Bool {
#if DEBUG
        let isJumpUnreadUITest = ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1"
        if isJumpUnreadUITest {
            writeJumpUnreadTestData([
                "jumpUnreadOpenCalled": "1",
                "jumpUnreadOpenTabId": tabId.uuidString,
                "jumpUnreadOpenSurfaceId": surfaceId?.uuidString ?? "",
            ])
        }
#endif
        guard let context = contextContainingTabId(tabId) else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "missing_context"
            )
            if isJumpUnreadUITest {
                writeJumpUnreadTestData(["jumpUnreadOpenContextFound": "0", "jumpUnreadOpenUsedFallback": "1"])
            }
#endif
            let ok = openNotificationFallback(
                tabId: tabId,
                surfaceId: surfaceId,
                panelId: panelId,
                notificationId: notificationId,
                scrollPosition: scrollPosition
            )
#if DEBUG
            if isJumpUnreadUITest {
                writeJumpUnreadTestData(["jumpUnreadOpenResult": ok ? "1" : "0"])
            }
#endif
            return ok
        }
#if DEBUG
        if isJumpUnreadUITest {
            writeJumpUnreadTestData(["jumpUnreadOpenContextFound": "1", "jumpUnreadOpenUsedFallback": "0"])
        }
#endif
        return openNotificationInContext(
            context,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            notificationId: notificationId,
            scrollPosition: scrollPosition
        )
    }

    func openNotificationInContext(
        _ context: MainWindowContext,
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        notificationId: UUID?,
        scrollPosition: TerminalNotificationScrollPosition? = nil
    ) -> Bool {
        let expectedIdentifier = "cmux.main.\(context.windowId.uuidString)"
        let window: NSWindow? = context.window ?? NSApp.windows.first(where: { $0.identifier?.rawValue == expectedIdentifier })
        guard let window else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "missing_window expectedIdentifier=\(expectedIdentifier)"
            )
#endif
            return false
        }

        context.sidebarSelectionState.selection = .tabs
        bringToFront(window)
        let focusSurfaceId = panelId ?? surfaceId
        guard context.tabManager.focusTabFromNotification(tabId, surfaceId: focusSurfaceId) else {
#if DEBUG
            recordMultiWindowNotificationOpenFailureIfNeeded(
                tabId: tabId,
                surfaceId: surfaceId,
                notificationId: notificationId,
                reason: "focus_failed"
            )
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadOpenResult": "0"])
            }
#endif
            return false
        }

#if DEBUG
        recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: context.tabManager,
            tabId: tabId,
            expectedSurfaceId: focusSurfaceId
        )
#endif

        lastNotificationOpenLanding = NotificationOpenLanding(window: window, tabManager: context.tabManager, workspaceId: tabId)
        if let notificationId, let store = notificationStore {
            store.markRead(id: notificationId)
        }
        restoreNotificationScrollPosition(
            scrollPosition,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            workspace: context.tabManager.tabs.first(where: { $0.id == tabId })
        )

#if DEBUG
        recordMultiWindowNotificationFocusIfNeeded(
            windowId: context.windowId,
            tabId: tabId,
            surfaceId: surfaceId,
            sidebarSelection: context.sidebarSelectionState.selection
        )
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(["jumpUnreadOpenInContext": "1", "jumpUnreadOpenResult": "1"])
        }
#endif
        return true
    }

    func openNotificationFallback(
        tabId: UUID,
        surfaceId: UUID?,
        panelId: UUID? = nil,
        notificationId: UUID?,
        scrollPosition: TerminalNotificationScrollPosition? = nil
    ) -> Bool {
        guard let tabManager else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "missing_tabManager"])
            }
#endif
            return false
        }
        guard tabManager.tabs.contains(where: { $0.id == tabId }) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "tab_not_in_active_manager"])
            }
#endif
            return false
        }
        guard let window = (NSApp.keyWindow ?? NSApp.windows.first(where: { isMainTerminalWindow($0) })) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData(["jumpUnreadFallbackFail": "missing_window"])
            }
#endif
            return false
        }

        sidebarSelectionState?.selection = .tabs
        bringToFront(window)
        let focusSurfaceId = panelId ?? surfaceId
        guard tabManager.focusTabFromNotification(tabId, surfaceId: focusSurfaceId) else {
#if DEBUG
            if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
                writeJumpUnreadTestData([
                    "jumpUnreadFallbackFail": "focus_failed",
                    "jumpUnreadOpenResult": "0",
                ])
            }
#endif
            return false
        }

#if DEBUG
        recordJumpUnreadFocusFromModelIfNeeded(
            tabManager: tabManager,
            tabId: tabId,
            expectedSurfaceId: focusSurfaceId
        )
#endif

        lastNotificationOpenLanding = NotificationOpenLanding(window: window, tabManager: tabManager, workspaceId: tabId)
        if let notificationId, let store = notificationStore {
            store.markRead(id: notificationId)
        }
        restoreNotificationScrollPosition(
            scrollPosition,
            tabId: tabId,
            surfaceId: surfaceId,
            panelId: panelId,
            workspace: tabManager.tabs.first(where: { $0.id == tabId })
        )
#if DEBUG
        if ProcessInfo.processInfo.environment["CMUX_UI_TEST_JUMP_UNREAD_SETUP"] == "1" {
            writeJumpUnreadTestData(["jumpUnreadOpenInFallback": "1", "jumpUnreadOpenResult": "1"])
        }
#endif
        return true
    }
}
