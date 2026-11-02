import AppKit
import OSLog

/// Detects a Claude Code turn the user interrupted with Esc or Ctrl+C.
///
/// Claude Code fires no hook for an interrupt (no Stop, no idle Notification),
/// so a pane's `claude_code` lifecycle stays `.running` until the next prompt.
/// What Claude Code does do is append a user entry whose only text is
/// `[Request interrupted by user]` (or `… for tool use]`) to the session
/// transcript. `Workspace.noteClaudeInterruptKey(panelId:)` queues one delayed
/// read of that transcript per key press burst; this namespace holds the
/// key match and the read-only transcript evidence.
enum ClaudeInterruptCheck {
    static let sentinelPrefix = "[Request interrupted by user"
    /// Entries Claude Code writes after the sentinel (snapshots, titles, cost
    /// state) are small; a quarter megabyte holds them many times over.
    static let tailByteLimit = 256 * 1024

    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "ClaudeInterruptCheck")

    /// Plain Esc or Ctrl+C: the two keys Claude Code hardcodes to interrupt a
    /// turn (Ctrl+D is exit only, which the SessionEnd hook already reports).
    /// Runs on every terminal keystroke, so ordinary typing only compares the
    /// key code and modifier flags; the layout-aware character lookup is
    /// reached only for Control-modified keys.
    static func isInterruptKey(_ event: NSEvent) -> Bool {
        let flags = ShortcutStroke.normalizedModifierFlags(from: event.modifierFlags)
        if event.keyCode == 53 { return flags.isEmpty }
        return flags == .control
            && (event.keyCode == 8 || event.charactersIgnoringModifiers?.lowercased() == "c")
    }

    /// Whether the newest main-chain user entry that carries text is Claude
    /// Code's interrupt sentinel. Tool results (no text) and subagent
    /// (sidechain) entries are skipped; any other text, such as a new prompt or
    /// a task notification, means the session moved past the interrupt.
    static func lastTurnWasInterrupted(transcriptTail: Data) -> Bool {
        for line in transcriptTail.split(separator: UInt8(ascii: "\n")).reversed() {
            guard let text = mainChainUserText(Data(line)) else { continue }
            return text.hasPrefix(sentinelPrefix)
        }
        return false
    }

    private static func mainChainUserText(_ line: Data) -> String? {
        guard line.range(of: Data(#""user""#.utf8)) != nil,
              let entry = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              entry["type"] as? String == "user",
              entry["isSidechain"] as? Bool != true,
              let message = entry["message"] as? [String: Any] else {
            return nil
        }
        switch message["content"] {
        case let text as String:
            return text
        case let blocks as [[String: Any]]:
            let texts = blocks.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
            return texts.isEmpty ? nil : texts.joined(separator: "\n")
        default:
            return nil
        }
    }

    /// The last `limit` bytes of the file, starting on a line boundary so a
    /// line cut in half by the window is never parsed.
    static func readTail(atPath path: String, limit: Int = tailByteLimit) throws -> Data {
        let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: path))
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let start = size > UInt64(limit) ? size - UInt64(limit) : 0
        try handle.seek(toOffset: start)
        let data = try handle.readToEnd() ?? Data()
        guard start > 0 else { return data }
        guard let newline = data.firstIndex(of: UInt8(ascii: "\n")) else { return Data() }
        return Data(data[data.index(after: newline)...])
    }

    /// The transcript of the newest Claude session the hook store bound to
    /// this panel. Matches on the panel id alone (panel ids are unique) so a
    /// pane moved to another workspace still resolves.
    static func transcriptPath(panelId: UUID, hookStore: Data) throws -> String? {
        let store = try JSONDecoder().decode(AgentHibernationTranscriptHookStoreFileMirror.self, from: hookStore)
        let panelRecords = (store.sessions ?? [:]).values.filter { record in
            guard let surfaceId = record.surfaceId?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
            return UUID(uuidString: surfaceId) == panelId && record.transcriptPath?.isEmpty == false
        }
        let newest = panelRecords.max { ($0.updatedAt ?? 0) < ($1.updatedAt ?? 0) }
        return newest?.transcriptPath.map { NSString(string: $0).expandingTildeInPath }
    }

    /// Hook store → transcript tail → sentinel, on a background thread.
    nonisolated static func panelTurnWasInterrupted(
        panelId: UUID,
        hookStoreURL: URL = RestorableAgentKind.claude.hookStoreFileURL()
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            do {
                guard let path = try transcriptPath(panelId: panelId, hookStore: Data(contentsOf: hookStoreURL)) else {
                    logger.info("no Claude transcript recorded for panel \(panelId.uuidString, privacy: .public)")
                    return false
                }
                let interrupted = lastTurnWasInterrupted(transcriptTail: try readTail(atPath: path))
                logger.info("panel \(panelId.uuidString, privacy: .public) interrupted=\(interrupted, privacy: .public)")
                return interrupted
            } catch {
                logger.error("interrupt check failed for panel \(panelId.uuidString, privacy: .public): \(String(describing: error), privacy: .public)")
                return false
            }
        }.value
    }
}
