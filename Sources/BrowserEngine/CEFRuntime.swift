import Foundation
import Bonsplit

/// Manages the CEF runtime lifecycle: initialization, message loop
/// pumping, and shutdown.
///
/// CEF must be initialized exactly once per app launch. After
/// initialization, the message loop must be pumped periodically
/// from the main thread. Shutdown happens at app termination.
final class CEFRuntime {

    static let shared = CEFRuntime()

    private var messageLoopTimer: Timer?
    private(set) var isInitialized = false
    private(set) var initError: String?

    private init() {}

    // MARK: - Initialization

    /// Initialize CEF using the bridge layer. Must be called from
    /// the main thread.
    ///
    /// Looks for the CEF framework in the app bundle's Frameworks/
    /// directory first, then falls back to the on-demand download
    /// location.
    ///
    /// Returns true on success.
    @discardableResult
    func initialize() -> Bool {
        guard !isInitialized else { return true }

        // Find the framework directory (parent of the .framework bundle)
        let frameworkDir = resolveFrameworkDir()
        guard let frameworkDir else {
            initError = "CEF framework not found in app bundle or download cache"
            return false
        }

        // Find the helper process
        let helperPath = resolveHelperPath()
        guard let helperPath else {
            initError = "CEF helper process not found"
            return false
        }

        // Cache root for CEF data
        let cacheRoot: String = {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let bundleID = Bundle.main.bundleIdentifier ?? "com.cmuxterm.app"
            return appSupport
                .appendingPathComponent(bundleID)
                .appendingPathComponent("CEFCache")
                .path
        }()

        try? FileManager.default.createDirectory(
            atPath: cacheRoot,
            withIntermediateDirectories: true
        )

#if DEBUG
        dlog("cef.init frameworkDir=\(frameworkDir) helperPath=\(helperPath) cacheRoot=\(cacheRoot)")
#endif
        let result = cef_bridge_initialize(frameworkDir, helperPath, cacheRoot)
#if DEBUG
        dlog("cef.init result=\(result)")
#endif
        if result == CEF_BRIDGE_OK {
            isInitialized = true
            initError = nil
            startMessageLoop()
            return true
        }

        initError = "CefInitialize failed (code \(result))"
        return false
    }

    // MARK: - Message Loop

    /// Start pumping the CEF message loop from the main thread.
    func startMessageLoop() {
        guard isInitialized, messageLoopTimer == nil else { return }
        messageLoopTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0,
            repeats: true
        ) { _ in
            cef_bridge_do_message_loop_work()
        }
    }

    func stopMessageLoop() {
        messageLoopTimer?.invalidate()
        messageLoopTimer = nil
    }

    // MARK: - Shutdown

    func shutdown() {
        stopMessageLoop()
        if isInitialized {
            cef_bridge_shutdown()
            isInitialized = false
        }
    }

    // MARK: - Version

    var version: String {
        guard let cstr = cef_bridge_get_version() else { return "unknown" }
        let str = String(cString: cstr)
        cef_bridge_free_string(cstr)
        return str
    }

    // MARK: - Path Resolution

    /// Resolve the directory containing "Chromium Embedded Framework.framework".
    /// Checks app bundle first, then on-demand download location.
    private func resolveFrameworkDir() -> String? {
        // 1. App bundle Frameworks/
        if let bundleFW = Bundle.main.privateFrameworksPath {
            let candidate = (bundleFW as NSString)
                .appendingPathComponent("Chromium Embedded Framework.framework")
            if FileManager.default.fileExists(atPath: candidate) {
                return bundleFW
            }
        }

        // 2. On-demand download location
        let downloadFW = CEFFrameworkManager.shared.frameworkPath.path
        if FileManager.default.fileExists(atPath: downloadFW) {
            return CEFFrameworkManager.shared.frameworksDir.path
        }

        return nil
    }

    /// Resolve the path to the CEF helper executable.
    private func resolveHelperPath() -> String? {
        // Look in app bundle Frameworks/
        if let bundleFW = Bundle.main.privateFrameworksPath {
            let candidate = (bundleFW as NSString)
                .appendingPathComponent("cmux Helper.app/Contents/MacOS/cmux Helper")
            if FileManager.default.fileExists(atPath: candidate) {
                return candidate
            }
        }
        return nil
    }
}
