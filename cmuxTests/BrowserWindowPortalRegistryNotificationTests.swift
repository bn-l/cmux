import AppKit
import Testing
import WebKit

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct BrowserWindowPortalRegistryNotificationTests {
    /// Counts explicit flushes even when AppKit has no dirty layout to apply.
    private final class CountingContentView: NSView {
        var layoutFlushCount = 0

        override func layoutSubtreeIfNeeded() {
            layoutFlushCount += 1
            super.layoutSubtreeIfNeeded()
        }
    }

    /// Supplies visibility to the workspace's window selection for the isolated
    /// fixture without depending on the test runner's active display state.
    private final class VisibleLayoutWindow: NSWindow {
        override var isVisible: Bool { true }
    }

    private func waitForNextMainTurn() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }

    private func realizeWindowLayout(_ window: NSWindow) {
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        window.contentView?.layoutSubtreeIfNeeded()
    }

    private func advanceAnimations() {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }

    private func hasOmnibarSuggestionsOverlay(in view: NSView) -> Bool {
        view.subviews.contains {
            String(describing: type(of: $0)).contains("OmnibarSuggestionsHostingView")
        }
    }

    @Test func registryDoesNotNotifyForUnchangedPortalVisibility() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 240),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)

        let anchor = NSView(frame: NSRect(x: 20, y: 20, width: 180, height: 120))
        contentView.addSubview(anchor)
        let webView = CmuxWebView(frame: .zero, configuration: WKWebViewConfiguration())

        var notificationCount = 0
        let observer = NotificationCenter.default.addObserver(
            forName: .browserPortalRegistryDidChange,
            object: webView,
            queue: nil
        ) { _ in
            notificationCount += 1
        }
        defer {
            NotificationCenter.default.removeObserver(observer)
            BrowserWindowPortalRegistry.detach(webView: webView)
        }

        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)
        advanceAnimations()
        #expect(notificationCount == 1)

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: true, zPriority: 0)
        #expect(
            notificationCount == 1,
            "Reapplying an unchanged portal visibility snapshot should not wake Workspace layout follow-up"
        )

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: false, zPriority: 0)
        #expect(notificationCount == 2)

        BrowserWindowPortalRegistry.updateEntryVisibility(for: webView, visibleInUI: false, zPriority: 0)
        #expect(
            notificationCount == 2,
            "Repeated hidden-state updates should not post duplicate registry-change notifications"
        )

        let slot = try #require(webView.superview as? WindowBrowserSlotView)
        #expect(!slot.isHidden)

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()
        #expect(slot.isHidden)
        #expect(
            notificationCount == 3,
            "A hidden visibility state whose slot still needs presentation sync should notify exactly once"
        )

        BrowserWindowPortalRegistry.hide(webView: webView, source: "unitTest")
        advanceAnimations()
        #expect(
            notificationCount == 3,
            "A repeated hide after state and presentation are already hidden should not notify"
        )
    }

    /// A split-zoom retry flushes its host window without touching peers.
    @Test func browserSplitZoomRetriesFlushOnlyOwningWindow() async throws {
        let contentView = CountingContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = VisibleLayoutWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()

        let unrelatedContentView = CountingContentView(frame: contentView.frame)
        let unrelatedWindow = VisibleLayoutWindow(
            contentRect: unrelatedContentView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        unrelatedWindow.contentView = unrelatedContentView
        defer { unrelatedWindow.orderOut(nil) }
        unrelatedWindow.orderFrontRegardless()
        #expect(NSApp.windows.contains { $0 === unrelatedWindow })

        let manager = TabManager()
        manager.window = window
        let workspace = try #require(manager.selectedWorkspace)
        defer { workspace.setPortalRenderingEnabled(false, reason: "test.cleanup") }
        let browserID = try #require(manager.openBrowser(inWorkspace: workspace.id, preferSplitRight: true))
        let browser = try #require(workspace.browserPanel(for: browserID))
        defer { BrowserWindowPortalRegistry.detach(webView: browser.webView) }

        // Use the product's zoom entry point. Only the browser is visible after
        // zoom, so terminal geometry converges on the first attempt. Its anchor
        // is deliberately unattached, leaving a real browser retry outstanding.
        #expect(browser.portalAnchorView.window == nil)
        #expect(workspace.toggleSplitZoom(panelId: browserID))
        #expect(workspace.bonsplitController.zoomedPaneId == workspace.paneId(forPanelId: browserID))
        contentView.layoutFlushCount = 0
        unrelatedContentView.layoutFlushCount = 0

        for _ in 0..<8 where contentView.layoutFlushCount < 2 {
            await waitForNextMainTurn()
        }
        #expect(
            contentView.layoutFlushCount >= 2,
            "The geometry pass and the later browser-only retry must each flush the owner"
        )
        #expect(
            unrelatedContentView.layoutFlushCount == 0,
            "Workspace retries must not flush an unrelated visible window"
        )
    }

    /// A browser visibility retry still flushes after terminal geometry settles.
    @Test func browserVisibilityRetryAfterGeometryPassFlushesOwningWindow() async throws {
        let contentView = CountingContentView(frame: NSRect(x: 0, y: 0, width: 640, height: 480))
        let window = VisibleLayoutWindow(
            contentRect: contentView.frame,
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.contentView = contentView
        defer { window.orderOut(nil) }
        window.orderFrontRegardless()

        let manager = TabManager()
        manager.window = window
        let workspace = try #require(manager.selectedWorkspace)
        let initialTerminalID = try #require(workspace.focusedPanelId)
        let browserID = try #require(manager.openBrowser(inWorkspace: workspace.id, preferSplitRight: true))
        let browser = try #require(workspace.browserPanel(for: browserID))
        #expect(workspace.closePanel(initialTerminalID, force: true))
        #expect(workspace.panels[initialTerminalID] == nil)
        defer {
            workspace.setPortalRenderingEnabled(false, reason: "test.cleanup")
            BrowserWindowPortalRegistry.detach(webView: browser.webView)
        }

        // Reset any setup follow-up, then enter through the geometry-only path.
        // The browser is the only rendered panel, so geometry converges while
        // its unattached anchor keeps browser visibility pending. That pending
        // browser retry must trigger a second scoped flush.
        workspace.setPortalRenderingEnabled(false, reason: "test.reset")
        contentView.layoutFlushCount = 0
        workspace.setPortalRenderingEnabled(true, reason: "test.geometryOnly")

        for _ in 0..<8 where contentView.layoutFlushCount < 2 {
            await waitForNextMainTurn()
        }
        #expect(
            contentView.layoutFlushCount >= 2,
            "A browser visibility retry after geometry convergence must flush its owner"
        )
    }

    @Test func browserPanelCloseDetachesPortalAndDismissesSuggestionsWhileCallbacksRetainPanel() throws {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        defer { window.orderOut(nil) }
        realizeWindowLayout(window)
        let contentView = try #require(window.contentView)
        let anchor = NSView(frame: NSRect(x: 24, y: 24, width: 360, height: 220))
        contentView.addSubview(anchor)

        let panel = BrowserPanel(
            workspaceId: UUID(),
            initialURL: URL(string: "about:blank")!,
            isRemoteWorkspace: false
        )
        let webView = panel.webView
        BrowserWindowPortalRegistry.bind(webView: webView, to: anchor, visibleInUI: true)
        BrowserWindowPortalRegistry.synchronizeForAnchor(anchor)

        var retainedPanel: BrowserPanel? = panel
        BrowserWindowPortalRegistry.updateSearchOverlay(
            for: webView,
            configuration: BrowserPortalSearchOverlayConfiguration(
                panelId: panel.id,
                searchState: BrowserSearchState(),
                focusRequestGeneration: 0,
                canApplyFocusRequest: { _ in retainedPanel != nil },
                onNext: { _ = retainedPanel?.id },
                onPrevious: { _ = retainedPanel?.id },
                onClose: { _ = retainedPanel?.id },
                onFieldDidFocus: { _ = retainedPanel?.id }
            )
        )
        let item = OmnibarSuggestion.search(engineName: "Google", query: "news")
        BrowserWindowPortalRegistry.updateOmnibarSuggestions(
            for: webView,
            configuration: BrowserPortalOmnibarSuggestionsConfiguration(
                panelId: panel.id,
                popupFrame: CGRect(x: 16, y: 16, width: 220, height: OmnibarSuggestionsView.popupHeight(for: [item])),
                colorScheme: .dark,
                engineName: "Google",
                items: [item],
                selectedIndex: 0,
                isLoadingRemoteSuggestions: false,
                searchSuggestionsEnabled: true,
                onCommit: { _ in _ = retainedPanel?.id },
                onHighlight: { _ in _ = retainedPanel?.id }
            )
        )

        let slot = try #require(webView.superview as? WindowBrowserSlotView)
        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: webView) != nil)
        #expect(slot.browserPortalTestSearchOverlayView != nil)
        #expect(hasOmnibarSuggestionsOverlay(in: slot))

        panel.close()

        #expect(BrowserWindowPortalRegistry.debugSnapshot(for: webView) == nil)
        #expect(slot.superview == nil)
        #expect(slot.browserPortalTestSearchOverlayView == nil)
        #expect(!hasOmnibarSuggestionsOverlay(in: slot))
        retainedPanel = nil
    }
}
