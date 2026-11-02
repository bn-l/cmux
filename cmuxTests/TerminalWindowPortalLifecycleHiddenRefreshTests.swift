@preconcurrency import XCTest
import AppKit
import CmuxTerminal

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

extension TerminalWindowPortalLifecycleTests {

    /// A workspace unmount removes its terminals' view trees from the window, so
    /// WindowServer stops compositing every parked terminal (gestures stayed slow
    /// with many workspaces open), but keeps the portal binding so reveal reattaches
    /// the same view. Upstream #12607, rewritten on this fork's portal test helpers.
    @MainActor
    func testWorkspaceUnmountDetachesTerminalAndRebindsOnReveal() throws {
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
        realizeWindowLayout(window)
        let contentView = try XCTUnwrap(window.contentView)
        let portal = WindowTerminalPortal(window: window)
        let anchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        contentView.addSubview(anchor)
        let surface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        realizeWindowLayout(window)
        let originalHost = try XCTUnwrap(surface.hostedView.superview, "The bound terminal should be in the window")
        let hostedId = ObjectIdentifier(surface.hostedView)

        surface.hostedView.setVisibleInUI(false)
        portal.hideEntry(forHostedId: hostedId)

        XCTAssertNil(
            surface.hostedView.superview,
            "An unmounted workspace must remove its terminal view tree from the window"
        )
        XCTAssertTrue(surface.hostedView.isHidden)
        XCTAssertTrue(
            portal.isHostedViewBoundToAnchor(withId: hostedId, anchorView: anchor),
            "Parking must keep the portal binding so the workspace can reattach on reveal"
        )
        XCTAssertTrue(
            portal.updateEntryVisibility(forHostedId: hostedId, visibleInUI: true),
            "A parked entry must report that it needs a reattach when it becomes visible"
        )

        surface.hostedView.setVisibleInUI(true)
        portal.bind(hostedView: surface.hostedView, to: anchor, visibleInUI: true)
        portal.synchronizeHostedViewForAnchor(anchor)
        drainMainQueue()
        realizeWindowLayout(window)

        XCTAssertTrue(surface.hostedView.superview === originalHost, "Reveal must reattach to the same host")
        XCTAssertTrue(surface.hostedView.window === window)
        XCTAssertFalse(surface.hostedView.isHidden, "A revealed terminal must be visible again")
        withExtendedLifetime(surface) {}
    }

    @MainActor
    func testPortalSkipsSynchronousRefreshForHiddenSurfaces() throws {
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
        realizeWindowLayout(window)
        guard let contentView = window.contentView else {
            XCTFail("Expected content view")
            return
        }

        let portal = WindowTerminalPortal(window: window)
        let visibleAnchor = NSView(frame: NSRect(x: 8, y: 8, width: 240, height: 160))
        let hiddenAnchor = NSView(frame: NSRect(x: 260, y: 8, width: 240, height: 160))
        contentView.addSubview(visibleAnchor)
        contentView.addSubview(hiddenAnchor)

        let visibleSurface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        let hiddenSurface = TerminalSurface(
            tabId: UUID(), context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil, workingDirectory: nil
        )
        portal.bind(hostedView: visibleSurface.hostedView, to: visibleAnchor, visibleInUI: true)
        portal.bind(hostedView: hiddenSurface.hostedView, to: hiddenAnchor, visibleInUI: false)
        portal.synchronizeHostedViewForAnchor(visibleAnchor)
        drainMainQueue()
        realizeWindowLayout(window)

        visibleSurface.resetDebugForceRefreshCount()
        hiddenSurface.resetDebugForceRefreshCount()

        // Move BOTH anchors: both hosted views get geometry bookkeeping, but
        // only the visible one may pay for the synchronous redraw — one
        // layout pass syncs every hosted view in the window, and a mirror
        // workspace parks 20+ surfaces on unselected tabs.
        visibleAnchor.setFrameSize(NSSize(width: 220, height: 150))
        hiddenAnchor.setFrameSize(NSSize(width: 220, height: 150))
        portal.synchronizeHostedViewForAnchor(visibleAnchor)
        drainMainQueue()

        XCTAssertEqual(
            hiddenSurface.debugForceRefreshCount(),
            0,
            "A hidden (unselected-tab) surface must not receive the synchronous GPU-blocking refresh on geometry sync"
        )
        withExtendedLifetime((visibleSurface, hiddenSurface)) {}
    }
}
