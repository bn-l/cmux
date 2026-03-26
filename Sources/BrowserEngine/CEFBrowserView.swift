import AppKit
import Combine
import Bonsplit

/// An NSView that hosts a CEF (Chromium) browser as a child window overlay.
///
/// Chrome runtime creates its own NSWindow with the full Chrome UI
/// (address bar, back/forward, context menus, extensions toolbar).
/// We position this window as a child of cmux's main window, overlaying
/// the panel area. No reparenting of views (which breaks CEF's compositor).
final class CEFBrowserView: NSView {

    // MARK: - Properties

    private var browserHandle: cef_bridge_browser_t?
    private var profileHandle: cef_bridge_profile_t?
    private var callbacksStorage: cef_bridge_client_callbacks?

    /// The CEF Chrome window (child window of cmux's main window).
    private var cefWindow: NSWindow?
    private var frameObservation: NSObjectProtocol?

    /// Deferred creation parameters.
    private var pendingURL: String?
    private var pendingCachePath: String?
    private var browserCreationAttempted = false

    @Published private(set) var currentURL: String = ""
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var isLoading: Bool = false
    @Published private(set) var canGoBack: Bool = false
    @Published private(set) var canGoForward: Bool = false

    weak var delegate: CEFBrowserViewDelegate?

    // MARK: - Initialization

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("CEFBrowserView does not support NSCoding")
    }

    deinit {
        detachChildWindow()
        destroyBrowser()
    }

    // MARK: - Browser Lifecycle

    func createBrowser(initialURL: String, cachePath: String?) {
        guard CEFRuntime.shared.isInitialized else {
            delegate?.cefBrowserView(self, didFailWithError: "CEF not initialized")
            return
        }
        guard browserHandle == nil, !browserCreationAttempted else { return }

        pendingURL = initialURL
        pendingCachePath = cachePath

        if bounds.width > 0, bounds.height > 0, window != nil {
            createBrowserNow()
        }
    }

    private func createBrowserNow() {
        guard let url = pendingURL, !browserCreationAttempted else { return }
        browserCreationAttempted = true

#if DEBUG
        dlog("cef.createBrowserNow url=\(url) bounds=\(bounds) window=\(window != nil)")
#endif

        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.createBrowserImmediate()
        }
    }

    private func createBrowserImmediate() {
        guard let url = pendingURL else { return }

        if let cachePath = pendingCachePath {
            profileHandle = cef_bridge_profile_create(cachePath)
        }

        var callbacks = cef_bridge_client_callbacks()
        let pointer = Unmanaged.passUnretained(self).toOpaque()
        callbacks.user_data = pointer
        callbacks.on_title_change = { _, title, userData in
            guard let userData, let title else { return }
            let view = Unmanaged<CEFBrowserView>.fromOpaque(userData).takeUnretainedValue()
            view.currentTitle = String(cString: title)
        }
        callbacks.on_url_change = { _, url, userData in
            guard let userData, let url else { return }
            let view = Unmanaged<CEFBrowserView>.fromOpaque(userData).takeUnretainedValue()
            view.currentURL = String(cString: url)
        }
        callbacks.on_loading_state_change = { _, loading, back, forward, userData in
            guard let userData else { return }
            let view = Unmanaged<CEFBrowserView>.fromOpaque(userData).takeUnretainedValue()
            view.isLoading = loading
            view.canGoBack = back
            view.canGoForward = forward
        }
        callbacks.on_navigation = { _, _, _, _ in }
        callbacks.on_fullscreen_change = { _, _, _ in }
        callbacks.on_popup_request = { _, _, _ in false }
        callbacks.on_console_message = { _, _, _, _, _, _ in }

        callbacksStorage = callbacks

        let w = Int32(bounds.width)
        let h = Int32(bounds.height)

        browserHandle = withUnsafePointer(to: &callbacksStorage!) { ptr in
            cef_bridge_browser_create(profileHandle, url, nil, w, h, ptr)
        }

#if DEBUG
        dlog("cef.createBrowserNow browserHandle=\(browserHandle != nil ? "created" : "NULL")")
#endif

        guard browserHandle != nil else {
            delegate?.cefBrowserView(self, didFailWithError: "Failed to create CEF browser")
            return
        }

        // Poll for CEF's Chrome window and attach it as a child window
        pollForCEFWindow()

        pendingURL = nil
        pendingCachePath = nil
    }

    // MARK: - Child Window Management

    private var windowPollCount = 0

    private func pollForCEFWindow() {
        windowPollCount += 1
        if attachChildWindow() {
#if DEBUG
            dlog("cef.windowAttached after \(windowPollCount) polls")
#endif
            return
        }
        if windowPollCount < 100 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.pollForCEFWindow()
            }
        } else {
#if DEBUG
            dlog("cef.windowNotFound gave up after \(windowPollCount) polls")
#endif
        }
    }

    private func attachChildWindow() -> Bool {
        guard let handle = browserHandle,
              let ptr = cef_bridge_browser_get_nsview(handle) else { return false }

        // The bridge returns the NSWindow for Chrome runtime
        let cefWin = Unmanaged<NSWindow>.fromOpaque(ptr).takeUnretainedValue()
        guard let parentWindow = self.window else { return false }

        self.cefWindow = cefWin

        // Configure the Chrome window as a borderless child
        cefWin.styleMask = [.borderless]
        cefWin.isOpaque = false
        cefWin.hasShadow = false
        cefWin.level = .normal

        // Position over our view's area in the parent window
        updateChildWindowFrame()

        // Add as child window so it moves/resizes with the parent
        parentWindow.addChildWindow(cefWin, ordered: .above)
        cefWin.orderFront(nil)

        // Observe frame changes to reposition the child window
        frameObservation = NotificationCenter.default.addObserver(
            forName: NSView.frameDidChangeNotification,
            object: self,
            queue: .main
        ) { [weak self] _ in
            self?.updateChildWindowFrame()
        }
        postsFrameChangedNotifications = true

        return true
    }

    private func updateChildWindowFrame() {
        guard let cefWin = cefWindow, let parentWindow = self.window else { return }
        // Convert our bounds to screen coordinates
        let frameInWindow = convert(bounds, to: nil)
        let frameOnScreen = parentWindow.convertToScreen(frameInWindow)
        cefWin.setFrame(frameOnScreen, display: true)
    }

    private func detachChildWindow() {
        if let obs = frameObservation {
            NotificationCenter.default.removeObserver(obs)
            frameObservation = nil
        }
        if let cefWin = cefWindow {
            cefWin.parent?.removeChildWindow(cefWin)
            cefWin.orderOut(nil)
            cefWindow = nil
        }
    }

    func destroyBrowser() {
        detachChildWindow()
        if let handle = browserHandle {
            cef_bridge_browser_destroy(handle)
            browserHandle = nil
        }
        if let profile = profileHandle {
            cef_bridge_profile_destroy(profile)
            profileHandle = nil
        }
        callbacksStorage = nil
    }

    // MARK: - Navigation

    func loadURL(_ urlString: String) {
        guard let handle = browserHandle else { return }
        cef_bridge_browser_load_url(handle, urlString)
    }

    func goBack() {
        guard let handle = browserHandle else { return }
        cef_bridge_browser_go_back(handle)
    }

    func goForward() {
        guard let handle = browserHandle else { return }
        cef_bridge_browser_go_forward(handle)
    }

    func reload() {
        guard let handle = browserHandle else { return }
        cef_bridge_browser_reload(handle)
    }

    func stopLoading() {
        guard let handle = browserHandle else { return }
        cef_bridge_browser_stop(handle)
    }

    // MARK: - DevTools

    func showDevTools() {
        guard let handle = browserHandle else { return }
        cef_bridge_browser_show_devtools(handle)
    }

    func closeDevTools() {
        guard let handle = browserHandle else { return }
        cef_bridge_browser_close_devtools(handle)
    }

    // MARK: - Visibility

    func notifyHidden(_ hidden: Bool) {
        guard let handle = browserHandle else { return }
        cef_bridge_browser_set_hidden(handle, hidden)
        cefWindow?.setIsVisible(!hidden)
    }

    func notifyResized() {
        guard let handle = browserHandle else { return }
        cef_bridge_browser_notify_resized(handle)
    }

    // MARK: - View Lifecycle

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil, bounds.width > 0, bounds.height > 0, pendingURL != nil {
            createBrowserNow()
        }
        if window == nil {
            detachChildWindow()
        }
    }

    override func layout() {
        super.layout()
        if pendingURL != nil, !browserCreationAttempted,
           bounds.width > 0, bounds.height > 0, window != nil {
            createBrowserNow()
        }
        updateChildWindowFrame()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        updateChildWindowFrame()
    }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        // Focus the CEF window on click
        cefWindow?.makeKeyAndOrderFront(nil)
    }

    override func rightMouseDown(with event: NSEvent) {
        // Forward right-click to CEF window
        cefWindow?.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Delegate Protocol

protocol CEFBrowserViewDelegate: AnyObject {
    func cefBrowserView(_ view: CEFBrowserView, didFailWithError message: String)
}

extension CEFBrowserViewDelegate {
    func cefBrowserView(_ view: CEFBrowserView, didFailWithError message: String) {}
}
