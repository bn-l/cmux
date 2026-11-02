import AppKit
import CmuxTerminal
import Testing

import CmuxSettings

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Upstream #12414: the workspace lifecycle decides whether a portal may
/// present, so a queued bind or visibility update cannot resurrect an
/// inactive workspace's terminal over the selected one.
@MainActor
@Suite(.serialized)
struct WorkspacePortalRenderingAuthorityTests {
    private struct Context {
        let manager: TabManager
        let selected: Workspace
        let inactive: Workspace
    }

    private func withRegisteredManager(_ body: (Context) throws -> Void) throws {
        let originalAppDelegate = AppDelegate.shared
        let appDelegate = originalAppDelegate ?? AppDelegate()
        let manager = TabManager(autoWelcomeIfNeeded: false)
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        AppDelegate.shared = appDelegate
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            AppDelegate.shared = originalAppDelegate
        }
        let selected = try #require(manager.selectedWorkspace)
        let inactive = manager.addWorkspace(select: false, placementOverride: .end)
        try body(Context(manager: manager, selected: selected, inactive: inactive))
    }

    @Test func inactiveWorkspaceCannotAuthorizePortalPresentation() throws {
        try withRegisteredManager { context in
            #expect(Workspace.portalRenderingEnabled(for: context.selected.id))
            #expect(!Workspace.portalRenderingEnabled(for: context.inactive.id))

            context.manager.selectedTabId = context.inactive.id

            #expect(!Workspace.portalRenderingEnabled(for: context.selected.id))
            #expect(Workspace.portalRenderingEnabled(for: context.inactive.id))
        }
    }

    @Test func disabledRenderingDeniesTheSelectedWorkspace() throws {
        try withRegisteredManager { context in
            context.selected.setPortalRenderingEnabled(false, reason: "test.disable")
            defer { context.selected.setPortalRenderingEnabled(true, reason: "test.restore") }

            #expect(!Workspace.portalRenderingEnabled(for: context.selected.id))
        }
    }

    @Test func unknownWorkspaceDoesNotHidePortals() {
        // Fork deviation: upstream denies a workspace no manager knows. Here a
        // surface whose workspace cannot be resolved keeps presenting.
        #expect(Workspace.portalRenderingEnabled(for: UUID()))
        #expect(Workspace.portalRenderingEnabled(for: nil))
    }

    @Test func staleBindForAnInactiveWorkspaceStaysHiddenUntilSelected() throws {
        try withRegisteredManager { context in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            defer {
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
                window.orderOut(nil)
            }
            let contentView = try #require(window.contentView)
            let portal = WindowTerminalPortal(window: window)
            let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
            contentView.addSubview(anchor)
            let surface = TerminalSurface(
                tabId: context.inactive.id, context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: nil, workingDirectory: nil
            )
            let hostedId = ObjectIdentifier(surface.hostedView)

            // A queued SwiftUI update for the inactive workspace asks to show it.
            portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
            portal.synchronizeHostedViewForAnchor(anchor)
            _ = portal.updateEntryVisibility(forHostedId: hostedId, visibleInUI: true)
            portal.synchronizeHostedViewForAnchor(anchor)

            #expect(surface.hostedView.isHidden, "An inactive workspace's terminal must not present over the selected one")

            context.manager.selectedTabId = context.inactive.id
            portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
            portal.synchronizeHostedViewForAnchor(anchor)

            #expect(!surface.hostedView.isHidden, "Selecting the workspace must let its terminal present again")
            withExtendedLifetime(surface) {}
        }
    }

    @Test func retiringAWorkspaceHidesItsRegisteredTerminals() throws {
        try withRegisteredManager { context in
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            defer {
                NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
                window.orderOut(nil)
            }
            let contentView = try #require(window.contentView)
            let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
            contentView.addSubview(anchor)
            let surface = TerminalSurface(
                tabId: context.selected.id, context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
                configTemplate: nil, workingDirectory: nil
            )
            TerminalWindowPortalRegistry.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
            TerminalWindowPortalRegistry.synchronizeForAnchor(anchor)
            defer { TerminalWindowPortalRegistry.detach(hostedView: surface.hostedView) }
            #expect(!surface.hostedView.isHidden)

            // The entry is no longer reachable through a mounted panel; retiring
            // the workspace must still find and hide it.
            TerminalWindowPortalRegistry.hideHostedViews(forWorkspaceID: context.selected.id)

            #expect(surface.hostedView.isHidden)
            withExtendedLifetime(surface) {}
        }
    }
}
