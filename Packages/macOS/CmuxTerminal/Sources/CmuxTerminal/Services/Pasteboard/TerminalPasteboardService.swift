public import AppKit
public import CmuxTerminalCore
public import GhosttyKit
import os

nonisolated private let terminalClipboardLogger = Logger(subsystem: "com.cmuxterm.app", category: "clipboard")

/// The terminal's pasteboard capability: clipboard reads and writes for the
/// ghostty runtime, plus materialization of pasteboard images into owned
/// temporary files for paste and drag flows.
///
/// Replaces the legacy `GhosttyPasteboardHelper` namespace enum. Exactly one
/// instance must serve the whole process: temporary-file ownership and the
/// one-shot write capture are process-wide hand-offs between independent call
/// sites (a file materialized by the paste path is cleaned up by an upload
/// completion), so splitting them across instances would silently leak files.
/// The composition point constructs the single instance and injects it.
///
/// Isolation design: callers are synchronous and arrive on several threads at
/// once. The ghostty write-clipboard callback fires on runtime threads and
/// cannot await, view paste paths run on the main actor, and upload
/// completions land on background queues. An actor would force `async` onto
/// the C callback path and `@MainActor` would require `assumeIsolated`, so the
/// service is nonisolated and `Sendable`: every method is a pure transform of
/// its pasteboard argument except two tiny lock-guarded values (the owned
/// temp-file set and the one-shot write capture), the sanctioned shape for
/// state shared with synchronous callbacks.
public final class TerminalPasteboardService: Sendable {
    /// One-shot interception slot for ``captureNextStandardClipboardWrite(_:)``.
    final class ClipboardWriteCapture: Sendable {
        private let lock = NSLock()
        // SAFETY: guarded by `lock`; written by the runtime's write-clipboard
        // callback thread and read by the capturing caller.
        nonisolated(unsafe) private var capturedValue: String?

        /// Stores the diverted clipboard string.
        func capture(_ value: String) {
            lock.lock()
            capturedValue = value
            lock.unlock()
        }

        /// The diverted clipboard string, if a write was captured.
        var value: String? {
            lock.lock()
            defer { lock.unlock() }
            return capturedValue
        }
    }

    static let utf8PlainTextType = NSPasteboard.PasteboardType("public.utf8-plain-text")
    static let temporaryImageFilenamePrefix = "clipboard-"
    static let objectReplacementCharacter = Character(UnicodeScalar(0xFFFC)!)
    /// Mirrors the clipboard-image size cap applied to every materialization
    /// path (local paste and remote-forwarded image bytes alike).
    static let maxClipboardImageSize = 10 * 1024 * 1024  // 10 MB

    // SAFETY: immutable reference; NSPasteboard handles are usable from any
    // thread and the legacy code already wrote to this pasteboard from
    // ghostty runtime threads.
    nonisolated(unsafe) private let standardPasteboard: NSPasteboard

    /// The directory that owned temporary image files are written into.
    let temporaryDirectory: URL

    private let temporaryImageOwnershipLock = NSLock()
    // SAFETY: guarded by `temporaryImageOwnershipLock`; mutated from
    // synchronous callers on arbitrary threads (paste paths, upload
    // completions, app termination cleanup).
    nonisolated(unsafe) private var ownedTemporaryImagePaths: Set<String> = []

    private let standardClipboardWriteCaptureLock = NSLock()
    // SAFETY: guarded by `standardClipboardWriteCaptureLock`; armed on the
    // capturing caller's thread and consumed by the runtime's
    // write-clipboard callback thread.
    nonisolated(unsafe) private var standardClipboardWriteCapture: ClipboardWriteCapture?

    /// Creates the process's pasteboard service.
    ///
    /// - Parameters:
    ///   - temporaryDirectory: Destination for owned temporary image files.
    ///     Tests inject a scratch directory; the app uses the user's
    ///     temporary directory.
    ///   - standardPasteboard: The system clipboard, which serves both the
    ///     standard and the selection location (see ``pasteboard(for:)``).
    ///     Tests inject a scratch board so they never touch the user's clipboard.
    public init(
        temporaryDirectory: URL = FileManager.default.temporaryDirectory,
        standardPasteboard: NSPasteboard = .general
    ) {
        self.temporaryDirectory = temporaryDirectory
        self.standardPasteboard = standardPasteboard
    }
}

extension TerminalPasteboardService: TerminalClipboardWriting {
    /// Writes a string to the given ghostty clipboard location, honoring an
    /// armed one-shot capture for the standard location.
    public func writeString(_ string: String, to location: ghostty_clipboard_e) {
        if location == GHOSTTY_CLIPBOARD_STANDARD {
            var capture: ClipboardWriteCapture?
            standardClipboardWriteCaptureLock.lock()
            capture = standardClipboardWriteCapture
            if capture != nil {
                standardClipboardWriteCapture = nil
            }
            standardClipboardWriteCaptureLock.unlock()

            if let capture {
                capture.capture(string)
                return
            }
        }

        // An empty payload carries nothing to paste; writing it would only
        // wipe what the user copied. Remote programs send it as an OSC 52
        // write (`ESC ] 52 ; c ; BEL`), which xterm defines as "clear".
        guard !string.isEmpty, let pasteboard = pasteboard(for: location) else {
            terminalClipboardLogger.notice(
                "clipboard.write.skipped location=\(location.rawValue, privacy: .public) length=\(string.utf8.count, privacy: .public)"
            )
            return
        }
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
        terminalClipboardLogger.notice(
            "clipboard.write location=\(location.rawValue, privacy: .public) length=\(string.utf8.count, privacy: .public) changeCount=\(pasteboard.changeCount, privacy: .public)"
        )
    }

    /// Arms a one-shot diversion of the next standard-clipboard write that
    /// happens while `action` runs, returning the diverted string.
    @discardableResult
    public func captureNextStandardClipboardWrite(_ action: () -> Bool) -> String? {
        let capture = ClipboardWriteCapture()
        standardClipboardWriteCaptureLock.lock()
        standardClipboardWriteCapture = capture
        standardClipboardWriteCaptureLock.unlock()

        defer {
            standardClipboardWriteCaptureLock.lock()
            if standardClipboardWriteCapture === capture {
                standardClipboardWriteCapture = nil
            }
            standardClipboardWriteCaptureLock.unlock()
        }

        guard action() else { return nil }
        return capture.value
    }
}

extension TerminalPasteboardService {
    /// The pasteboard backing a ghostty clipboard location.
    ///
    /// The selection location shares the system clipboard. Ghostty 1.4.0 has no
    /// selection clipboard on macOS: copy-on-select defaults to `none` and never
    /// fills one, so a separate board would only hold whatever was selected
    /// under an older Ghostty, and Cmd+Shift+V, Shift+Insert and middle-click
    /// (`paste_from_selection`, `primary-paste`) would paste that instead of
    /// what the user copied. A program writing the selection (OSC 52 `s`) lands
    /// on the clipboard, as in iTerm2. The primary selection does not exist on
    /// macOS.
    public func pasteboard(for location: ghostty_clipboard_e) -> NSPasteboard? {
        switch location {
        case GHOSTTY_CLIPBOARD_STANDARD, GHOSTTY_CLIPBOARD_SELECTION:
            return standardPasteboard
        default:
            return nil
        }
    }

    /// Whether the file was materialized by this service and is still owned.
    public func isOwnedTemporaryImageFile(_ fileURL: URL) -> Bool {
        let normalizedPath = fileURL.standardizedFileURL.path
        temporaryImageOwnershipLock.lock()
        let isOwned = ownedTemporaryImagePaths.contains(normalizedPath)
        temporaryImageOwnershipLock.unlock()
        return isOwned
    }

    /// Deletes the given files if (and only if) this service still owns them,
    /// consuming ownership.
    public func cleanupTransferredTemporaryImageFiles(_ fileURLs: [URL]) {
        for fileURL in fileURLs {
            let normalizedURL = fileURL.standardizedFileURL
            guard normalizedURL.isFileURL,
                  consumeOwnedTemporaryImageFile(normalizedURL) else {
                continue
            }
            try? FileManager.default.removeItem(at: normalizedURL)
        }
    }

    /// Deletes every temporary image file this service still owns.
    public func cleanupAllOwnedTemporaryImageFiles() {
        temporaryImageOwnershipLock.lock()
        let paths = ownedTemporaryImagePaths
        ownedTemporaryImagePaths.removeAll()
        temporaryImageOwnershipLock.unlock()

        for path in paths {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: path))
        }
    }

    func registerOwnedTemporaryImageFile(_ fileURL: URL) {
        let normalizedPath = fileURL.standardizedFileURL.path
        temporaryImageOwnershipLock.lock()
        ownedTemporaryImagePaths.insert(normalizedPath)
        temporaryImageOwnershipLock.unlock()
    }

    private func consumeOwnedTemporaryImageFile(_ fileURL: URL) -> Bool {
        let normalizedPath = fileURL.standardizedFileURL.path
        temporaryImageOwnershipLock.lock()
        let didOwnFile = ownedTemporaryImagePaths.remove(normalizedPath) != nil
        temporaryImageOwnershipLock.unlock()
        return didOwnFile
    }

#if DEBUG
    /// Test bridge: registers an arbitrary file as owned so cleanup paths can
    /// be exercised deterministically.
    public func debugRegisterOwnedTemporaryImageFile(_ fileURL: URL) {
        registerOwnedTemporaryImageFile(fileURL)
    }
#endif
}
