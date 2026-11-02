import AppKit
import Foundation
import Testing
import XCTest

import CmuxSidebar

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Transcript lines shaped like Claude Code 2.1's JSONL (keys and nesting
/// copied from real interrupted sessions).
private enum Transcript {
    static let sessionId = "44993ac2-b255-4883-ba8b-7f4d5fb9e6b4"
    static let streamSentinel = "[Request interrupted by user]"
    static let toolSentinel = "[Request interrupted by user for tool use]"

    static func line(_ object: [String: Any]) throws -> String {
        try #require(String(data: JSONSerialization.data(withJSONObject: object), encoding: .utf8))
    }

    static func user(_ content: Any, sidechain: Bool = false, extra: [String: Any] = [:]) throws -> String {
        try line([
            "parentUuid": UUID().uuidString,
            "isSidechain": sidechain,
            "type": "user",
            "message": ["role": "user", "content": content],
            "uuid": UUID().uuidString,
            "timestamp": "2026-11-03T04:00:00.000Z",
            "userType": "external",
            "entrypoint": "cli",
            "cwd": "/tmp/project",
            "sessionId": sessionId,
        ].merging(extra) { $1 })
    }

    /// Typed prompts are stored as plain string content.
    static func prompt(_ text: String) throws -> String { try user(text) }

    /// Interrupt sentinels are stored as a single text block.
    static func textBlock(_ text: String, sidechain: Bool = false) throws -> String {
        try user([["type": "text", "text": text]], sidechain: sidechain)
    }

    static func toolResult(_ output: String) throws -> String {
        try user([["type": "tool_result", "tool_use_id": "toolu_01", "content": output]])
    }

    static func rejectedToolResult() throws -> String {
        try user(
            [["type": "tool_result", "is_error": true, "tool_use_id": "toolu_01",
              "content": "The user doesn't want to proceed with this tool use."]],
            extra: ["toolDenialKind": "user-rejected"]
        )
    }

    static func assistant(_ text: String) throws -> String {
        try line([
            "isSidechain": false, "type": "assistant", "uuid": UUID().uuidString, "sessionId": sessionId,
            "message": ["role": "assistant", "content": [["type": "text", "text": text]]],
        ])
    }

    static func assistantToolUse() throws -> String {
        try line([
            "isSidechain": false, "type": "assistant", "uuid": UUID().uuidString, "sessionId": sessionId,
            "message": ["role": "assistant", "content": [
                ["type": "tool_use", "id": "toolu_01", "name": "Bash", "input": ["command": "sleep 600"]],
            ]],
        ])
    }

    /// Non-message entries Claude Code appends after an interrupt. Several carry
    /// the user's text, which must not be mistaken for a user entry.
    static func bookkeeping() throws -> [String] {
        [
            try line(["type": "file-history-snapshot", "messageId": UUID().uuidString, "snapshot": [:]]),
            try line(["type": "queue-operation", "operation": "enqueue", "sessionId": sessionId, "content": "next prompt"]),
            try line(["type": "last-prompt", "lastPrompt": "fix the build", "sessionId": sessionId]),
            try line(["type": "ai-title", "aiTitle": "Fix the build", "sessionId": sessionId]),
            try line(["type": "system", "subtype": "local_command", "content": streamSentinel]),
            // Claude Code 2.1.316 entry kinds seen after a real interrupt.
            try line(["type": "mode", "mode": "default", "sessionId": sessionId]),
            try line(["type": "permission-mode", "permissionMode": "default", "sessionId": sessionId]),
            try line(["type": "atis-latch", "atis": [:], "sessionId": sessionId]),
            try line(["type": "tools-used", "sessionId": sessionId]),
        ]
    }

    /// 2.1.316 replays the request history as an `api-request-blob` whose
    /// message has role "user" but is not a user entry.
    static func apiRequestBlob(_ texts: [String]) throws -> String {
        try line([
            "type": "api-request-blob", "sessionId": sessionId, "hash": "97c9091d",
            "message": ["role": "user", "content": texts.map { ["type": "text", "text": $0] }],
        ])
    }

    static func data(_ lines: [String]) -> Data {
        Data((lines.joined(separator: "\n") + "\n").utf8)
    }
}

private actor ReadCounter {
    private(set) var count = 0
    func hit() { count += 1 }
}

// MARK: - Transcript evidence

struct ClaudeInterruptTranscriptTests {
    @Test func streamingInterruptIsDetected() throws {
        let tail = try Transcript.data([
            try Transcript.prompt("fix the build"),
            try Transcript.assistant("Looking at the failing target"),
            try Transcript.textBlock(Transcript.streamSentinel),
        ] + Transcript.bookkeeping())

        #expect(ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: tail))
    }

    @Test func toolUseInterruptAfterRejectedToolResultIsDetected() throws {
        let tail = try Transcript.data([
            try Transcript.prompt("run the tests"),
            try Transcript.assistantToolUse(),
            try Transcript.rejectedToolResult(),
            try Transcript.textBlock(Transcript.toolSentinel),
        ] + Transcript.bookkeeping())

        #expect(ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: tail))
    }

    @Test func sentinelStoredAsStringContentIsDetected() throws {
        let tail = Transcript.data([try Transcript.prompt("go"), try Transcript.user(Transcript.streamSentinel)])

        #expect(ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: tail))
    }

    @Test func promptAfterTheInterruptMeansTheSessionMovedOn() throws {
        let tail = try Transcript.data([
            try Transcript.textBlock(Transcript.streamSentinel),
        ] + Transcript.bookkeeping() + [
            try Transcript.prompt("actually, do this instead"),
        ])

        #expect(!ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: tail))
    }

    @Test func taskNotificationAfterTheInterruptMeansTheSessionMovedOn() throws {
        let tail = Transcript.data([
            try Transcript.textBlock(Transcript.streamSentinel),
            try Transcript.prompt("<task-notification><task-id>b1</task-id><status>completed</status></task-notification>"),
        ])

        #expect(!ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: tail))
    }

    @Test func runningTurnWithToolResultsIsNotInterrupted() throws {
        let tail = Transcript.data([
            try Transcript.textBlock(Transcript.streamSentinel),
            try Transcript.prompt("try again"),
            try Transcript.assistantToolUse(),
            try Transcript.toolResult("ok"),
        ])

        #expect(
            !ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: tail),
            "Tool results carry no text; the newest text is the new prompt, not the older sentinel"
        )
    }

    @Test func subagentInterruptDoesNotCountForTheMainChain() throws {
        let tail = Transcript.data([
            try Transcript.prompt("research this"),
            try Transcript.assistantToolUse(),
            try Transcript.textBlock(Transcript.streamSentinel, sidechain: true),
        ])

        #expect(!ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: tail))
    }

    @Test func sidechainTextAfterAMainChainInterruptIsSkipped() throws {
        let tail = Transcript.data([
            try Transcript.textBlock(Transcript.streamSentinel),
            try Transcript.textBlock("subagent prompt", sidechain: true),
        ])

        #expect(ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: tail))
    }

    @Test func sentinelTextOutsideAUserEntryStartIsIgnored() throws {
        let quoted = Transcript.data([
            try Transcript.prompt("why do I see \(Transcript.streamSentinel) in the log?"),
            try Transcript.assistant(Transcript.streamSentinel),
        ])

        #expect(!ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: quoted))
    }

    @Test func replayedHistoryBlobIsNotAUserEntry() throws {
        let tail = Transcript.data([
            try Transcript.prompt("keep going"),
            try Transcript.assistant("Continuing"),
            try Transcript.apiRequestBlob([Transcript.streamSentinel + "\n", "keep going"]),
            try Transcript.apiRequestBlob([Transcript.streamSentinel]),
        ])

        #expect(
            !ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: tail),
            "A role-user request blob replaying an old sentinel must not read as a new interrupt"
        )
    }

    @Test func halfWrittenTrailingLineIsSkipped() throws {
        var tail = Transcript.data([try Transcript.textBlock(Transcript.streamSentinel)])
        tail.append(Data(#"{"type":"user","message":{"role":"user","content":"half writ"#.utf8))

        #expect(ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: tail))
    }

    @Test func emptyOrGarbageTailIsNotInterrupted() {
        #expect(!ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: Data()))
        #expect(!ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: Data("not json\n\u{0}\u{1}\n".utf8)))
    }
}

// MARK: - Reading the transcript tail

struct ClaudeInterruptTranscriptTailTests {
    private func temporaryFile(_ data: Data) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-interrupt-tail-\(UUID().uuidString).jsonl")
        try data.write(to: url)
        return url
    }

    @Test func smallFileIsReadWhole() throws {
        let data = Transcript.data([try Transcript.prompt("go"), try Transcript.textBlock(Transcript.streamSentinel)])
        let url = try temporaryFile(data)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(try ClaudeInterruptCheck.readTail(atPath: url.path) == data)
    }

    @Test func largeFileTailStartsOnALineBoundary() throws {
        let filler = try (0..<200).map { try Transcript.prompt("filler prompt number \($0)") }
        let url = try temporaryFile(Transcript.data(filler + [try Transcript.textBlock(Transcript.streamSentinel)]))
        defer { try? FileManager.default.removeItem(at: url) }

        let tail = try ClaudeInterruptCheck.readTail(atPath: url.path, limit: 4096)

        #expect(tail.count <= 4096)
        #expect(tail.first == UInt8(ascii: "{"), "The tail must drop the line the window cut in half")
        for line in tail.split(separator: UInt8(ascii: "\n")) {
            #expect((try? JSONSerialization.jsonObject(with: Data(line))) != nil, "Every tail line must be whole JSON")
        }
        #expect(ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: tail))
    }

    @Test func windowInsideOneLongLineYieldsNothing() throws {
        let longAssistant = try Transcript.assistant(String(repeating: "x", count: 10_000))
        let url = try temporaryFile(Transcript.data([try Transcript.textBlock(Transcript.streamSentinel), longAssistant]))
        defer { try? FileManager.default.removeItem(at: url) }

        let tail = try ClaudeInterruptCheck.readTail(atPath: url.path, limit: 4096)

        #expect(tail.isEmpty, "A window that starts inside the final line holds no whole line")
        #expect(
            !ClaudeInterruptCheck.lastTurnWasInterrupted(transcriptTail: tail),
            "A sentinel older than the window is out of reach by design"
        )
    }

    @Test func missingFileThrows() {
        #expect(throws: (any Error).self) {
            try ClaudeInterruptCheck.readTail(atPath: "/nonexistent/\(UUID().uuidString).jsonl")
        }
    }
}

// MARK: - Hook store → transcript path

struct ClaudeInterruptHookStoreTests {
    private func store(_ records: [[String: Any]]) throws -> Data {
        var sessions: [String: Any] = [:]
        for record in records { sessions[UUID().uuidString] = record }
        return try JSONSerialization.data(withJSONObject: ["version": 1, "sessions": sessions])
    }

    @Test func newestRecordForThePanelWins() throws {
        let panelId = UUID()
        let data = try store([
            ["sessionId": "old", "surfaceId": panelId.uuidString, "transcriptPath": "/t/old.jsonl", "updatedAt": 100.0],
            ["sessionId": "new", "surfaceId": panelId.uuidString.lowercased(), "transcriptPath": "/t/new.jsonl", "updatedAt": 300.0],
            ["sessionId": "other", "surfaceId": UUID().uuidString, "transcriptPath": "/t/other.jsonl", "updatedAt": 900.0],
            ["sessionId": "blank", "surfaceId": panelId.uuidString, "transcriptPath": "", "updatedAt": 999.0],
        ])

        #expect(try ClaudeInterruptCheck.transcriptPath(panelId: panelId, hookStore: data) == "/t/new.jsonl")
    }

    @Test func tildePathIsExpanded() throws {
        let panelId = UUID()
        let data = try store([["surfaceId": " \(panelId.uuidString) ", "transcriptPath": "~/t.jsonl", "updatedAt": 1.0]])

        #expect(try ClaudeInterruptCheck.transcriptPath(panelId: panelId, hookStore: data) == NSString(string: "~/t.jsonl").expandingTildeInPath)
    }

    @Test func unknownPanelHasNoTranscript() throws {
        let data = try store([["surfaceId": UUID().uuidString, "transcriptPath": "/t/a.jsonl", "updatedAt": 1.0]])

        #expect(try ClaudeInterruptCheck.transcriptPath(panelId: UUID(), hookStore: data) == nil)
    }

    @Test func corruptStoreThrows() {
        #expect(throws: (any Error).self) {
            try ClaudeInterruptCheck.transcriptPath(panelId: UUID(), hookStore: Data("{".utf8))
        }
    }

    @Test func panelCheckReadsStoreAndTranscriptFromDisk() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-interrupt-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let interruptedPanel = UUID(), runningPanel = UUID(), missingTranscriptPanel = UUID()
        let interrupted = directory.appendingPathComponent("interrupted.jsonl")
        let running = directory.appendingPathComponent("running.jsonl")
        try Transcript.data([try Transcript.prompt("go"), try Transcript.textBlock(Transcript.toolSentinel)]).write(to: interrupted)
        try Transcript.data([try Transcript.prompt("go"), try Transcript.assistantToolUse()]).write(to: running)
        let storeURL = directory.appendingPathComponent("claude-hook-sessions.json")
        try store([
            ["surfaceId": interruptedPanel.uuidString, "transcriptPath": interrupted.path, "updatedAt": 1.0],
            ["surfaceId": runningPanel.uuidString, "transcriptPath": running.path, "updatedAt": 1.0],
            ["surfaceId": missingTranscriptPanel.uuidString, "transcriptPath": directory.appendingPathComponent("gone.jsonl").path, "updatedAt": 1.0],
        ]).write(to: storeURL)

        #expect(await ClaudeInterruptCheck.panelTurnWasInterrupted(panelId: interruptedPanel, hookStoreURL: storeURL))
        #expect(!(await ClaudeInterruptCheck.panelTurnWasInterrupted(panelId: runningPanel, hookStoreURL: storeURL)))
        #expect(!(await ClaudeInterruptCheck.panelTurnWasInterrupted(panelId: missingTranscriptPanel, hookStoreURL: storeURL)))
        #expect(!(await ClaudeInterruptCheck.panelTurnWasInterrupted(panelId: UUID(), hookStoreURL: storeURL)))
        #expect(!(await ClaudeInterruptCheck.panelTurnWasInterrupted(
            panelId: interruptedPanel,
            hookStoreURL: directory.appendingPathComponent("no-store.json")
        )))
    }
}

// MARK: - Interrupt keys

@MainActor
struct ClaudeInterruptKeyTests {
    private func key(_ chars: String, ignoring: String? = nil, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
            characters: chars, charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: keyCode
        ))
    }

    @Test func escAndCtrlCAreInterruptKeys() throws {
        #expect(ClaudeInterruptCheck.isInterruptKey(try key("\u{1b}", keyCode: 53)))
        #expect(ClaudeInterruptCheck.isInterruptKey(try key("\u{3}", ignoring: "c", keyCode: 8, .control)))
        #expect(ClaudeInterruptCheck.isInterruptKey(try key("\u{3}", ignoring: "c", keyCode: 8, [.control, .capsLock])))
        // Dvorak: the C character sits on the QWERTY "I" key.
        #expect(ClaudeInterruptCheck.isInterruptKey(try key("\u{3}", ignoring: "c", keyCode: 34, .control)))
    }

    @Test func otherKeysAreNot() throws {
        #expect(!ClaudeInterruptCheck.isInterruptKey(try key("c", keyCode: 8)))
        #expect(!ClaudeInterruptCheck.isInterruptKey(try key("c", keyCode: 8, .command)))
        #expect(!ClaudeInterruptCheck.isInterruptKey(try key("\u{3}", ignoring: "C", keyCode: 8, [.control, .shift])))
        #expect(!ClaudeInterruptCheck.isInterruptKey(try key("\u{4}", ignoring: "d", keyCode: 2, .control)), "Ctrl+D exits Claude; SessionEnd covers it")
        #expect(!ClaudeInterruptCheck.isInterruptKey(try key("\u{1b}", keyCode: 53, .option)))
        #expect(!ClaudeInterruptCheck.isInterruptKey(try key("\u{1b}", keyCode: 53, .shift)))
    }
}

// MARK: - Workspace scheduling

@MainActor
@Suite(.serialized)
struct ClaudeInterruptWorkspaceTests {
    private let key = Workspace.claudeInterruptStatusKey
    private let idleValue = String(localized: "agent.generic.notification.status.idle", defaultValue: "Idle")

    private func runningWorkspace(_ lifecycle: AgentHibernationLifecycleState = .running) throws -> (Workspace, UUID) {
        let workspace = Workspace()
        let panelId = try #require(workspace.focusedPanelId)
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: lifecycle)
        workspace.statusEntries[key] = SidebarStatusEntry(key: key, value: "Running", icon: "bolt.fill", color: "#4C8DFF")
        return (workspace, panelId)
    }

    @Test func interruptedRunningTurnBecomesIdle() async throws {
        let (workspace, panelId) = try runningWorkspace()

        let check = workspace.noteClaudeInterruptKey(panelId: panelId, delay: .zero) { _ in true }
        await check?.value

        #expect(check != nil)
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?[key] == .idle)
        let status = try #require(workspace.statusEntries[key])
        #expect(status.value == idleValue)
        #expect(status.icon == "pause.circle.fill")
        #expect(status.color == "#8E8E93")
        #expect(workspace.pendingClaudeInterruptCheckTokens[panelId] == nil)
    }

    @Test func permissionPromptRejectedWithEscBecomesIdle() async throws {
        let (workspace, panelId) = try runningWorkspace(.needsInput)

        await workspace.noteClaudeInterruptKey(panelId: panelId, delay: .zero) { _ in true }?.value

        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?[key] == .idle)
        #expect(workspace.statusEntries[key]?.value == idleValue)
    }

    @Test func turnWithoutSentinelStaysRunning() async throws {
        let (workspace, panelId) = try runningWorkspace()

        await workspace.noteClaudeInterruptKey(panelId: panelId, delay: .zero) { _ in false }?.value

        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?[key] == .running)
        #expect(workspace.statusEntries[key]?.value == "Running")
        #expect(workspace.pendingClaudeInterruptCheckTokens[panelId] == nil, "A finished check must not leave the pane pending")
    }

    @Test func repeatedPressesWhilePendingQueueOneCheck() async throws {
        let (workspace, panelId) = try runningWorkspace()
        let reads = ReadCounter()
        let reader: @Sendable (UUID) async -> Bool = { _ in await reads.hit(); return true }

        let first = workspace.noteClaudeInterruptKey(panelId: panelId, delay: .milliseconds(100), turnWasInterrupted: reader)
        let repeats = (0..<5).map { _ in
            workspace.noteClaudeInterruptKey(panelId: panelId, delay: .milliseconds(100), turnWasInterrupted: reader)
        }
        await first?.value

        #expect(first != nil)
        #expect(repeats.allSatisfy { $0 == nil })
        #expect(await reads.count == 1)
        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?[key] == .idle)
    }

    @Test func pressAfterACompletedCheckQueuesAgain() async throws {
        let (workspace, panelId) = try runningWorkspace()
        let reads = ReadCounter()
        let reader: @Sendable (UUID) async -> Bool = { _ in await reads.hit(); return false }

        await workspace.noteClaudeInterruptKey(panelId: panelId, delay: .zero, turnWasInterrupted: reader)?.value
        let second = workspace.noteClaudeInterruptKey(panelId: panelId, delay: .zero, turnWasInterrupted: reader)
        await second?.value

        #expect(second != nil)
        #expect(await reads.count == 2)
    }

    @Test func closedTurnsQueueNothing() async throws {
        let reads = ReadCounter()
        let reader: @Sendable (UUID) async -> Bool = { _ in await reads.hit(); return true }
        for lifecycle: AgentHibernationLifecycleState in [.idle, .unknown] {
            let (workspace, panelId) = try runningWorkspace(lifecycle)
            #expect(workspace.noteClaudeInterruptKey(panelId: panelId, delay: .zero, turnWasInterrupted: reader) == nil)
        }
        let bare = Workspace()
        let barePanel = try #require(bare.focusedPanelId)
        #expect(bare.noteClaudeInterruptKey(panelId: barePanel, delay: .zero, turnWasInterrupted: reader) == nil)
        bare.setAgentLifecycle(key: "codex", panelId: barePanel, lifecycle: .running)
        #expect(
            bare.noteClaudeInterruptKey(panelId: barePanel, delay: .zero, turnWasInterrupted: reader) == nil,
            "Only a Claude turn writes the Claude sentinel"
        )
        #expect(await reads.count == 0)
    }

    @Test func hookReportDuringTheTranscriptReadWins() async throws {
        let (workspace, panelId) = try runningWorkspace()
        let key = key

        // The user re-submits while the transcript is being read: the
        // prompt-submit hook re-asserts .running through the socket path.
        await workspace.noteClaudeInterruptKey(panelId: panelId, delay: .zero) { _ in
            await MainActor.run {
                workspace.supersedeClaudeInterruptCheck(key: key, panelId: panelId)
                workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
            }
            return true
        }?.value

        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?[key] == .running)
        #expect(workspace.statusEntries[key]?.value == "Running")
    }

    @Test func appSideLifecycleWriteDoesNotCancel() async throws {
        let (workspace, panelId) = try runningWorkspace(.needsInput)

        let check = workspace.noteClaudeInterruptKey(panelId: panelId, delay: .milliseconds(50)) { _ in true }
        // The feed concluding the rejected permission request flips
        // needsInput back to running from inside the app, not from a hook.
        workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
        await check?.value

        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?[key] == .idle)
    }

    @Test func sessionEndDuringTheDelayLeavesStatusAlone() async throws {
        let (workspace, panelId) = try runningWorkspace()

        let check = workspace.noteClaudeInterruptKey(panelId: panelId, delay: .milliseconds(50)) { _ in true }
        workspace.clearAgentLifecycle(key: key, panelId: panelId)
        await check?.value

        #expect(workspace.agentLifecycleStatesByPanelId[panelId]?[key] == nil)
        #expect(workspace.statusEntries[key]?.value == "Running")
    }

    @Test func anotherOpenClaudeTurnKeepsTheWorkspacePill() async throws {
        let (workspace, firstPanel) = try runningWorkspace()
        let paneId = try #require(workspace.paneId(forPanelId: firstPanel))
        let secondPanel = try #require(workspace.newTerminalSurface(inPane: paneId, focus: false)).id
        workspace.setAgentLifecycle(key: key, panelId: secondPanel, lifecycle: .running)

        await workspace.noteClaudeInterruptKey(panelId: firstPanel, delay: .zero) { _ in true }?.value

        #expect(workspace.agentLifecycleStatesByPanelId[firstPanel]?[key] == .idle)
        #expect(workspace.agentLifecycleStatesByPanelId[secondPanel]?[key] == .running)
        #expect(workspace.statusEntries[key]?.value == "Running")
    }

    @Test func hookLifecycleThroughTheSocketCancelsAPendingCheck() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousManager = TerminalController.shared.activeTabManagerForCallerNotification()
            let manager = TabManager()
            TerminalController.shared.setActiveTabManager(manager)
            defer {
                TerminalController.shared.setActiveTabManager(previousManager)
                TerminalMutationBus.shared.drainForTesting()
            }
            let workspace = try #require(manager.selectedWorkspace)
            let panelId = try #require(workspace.focusedPanelId)
            workspace.setAgentLifecycle(key: key, panelId: panelId, lifecycle: .running)
            let reads = ReadCounter()

            let check = workspace.noteClaudeInterruptKey(panelId: panelId, delay: .milliseconds(200)) { _ in
                await reads.hit()
                return true
            }
            let response = TerminalController.shared.handleSocketLine(
                "set_agent_lifecycle claude_code running --tab=\(workspace.id.uuidString) --panel=\(panelId.uuidString)"
            )
            TerminalMutationBus.shared.drainForTesting()
            await check?.value

            #expect(response == "OK")
            #expect(await reads.count == 0, "A hook report must cancel the queued check before it reads")
            #expect(workspace.agentLifecycleStatesByPanelId[panelId]?[key] == .running)
        }
    }
}

// MARK: - Through the terminal's keyDown

@MainActor
final class ClaudeInterruptKeyDownTests: XCTestCase {
    private struct Harness {
        let workspace: Workspace
        let panelId: UUID
        let surfaceView: GhosttyNSView
        let window: NSWindow
    }

    private func withHarness(_ body: (Harness) throws -> Void) throws {
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let manager = TabManager()
        let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        defer {
            appDelegate.unregisterMainWindowContextForTesting(windowId: windowId)
            window.orderOut(nil)
        }
        let workspace = try XCTUnwrap(manager.selectedWorkspace)
        let panel = try XCTUnwrap(workspace.focusedTerminalPanel)
        let contentView = try XCTUnwrap(window.contentView)
        let hostedView = panel.hostedView
        hostedView.frame = contentView.bounds
        contentView.addSubview(hostedView)
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        let surfaceView = try XCTUnwrap(
            hostedView.subviews.compactMap { $0 as? NSScrollView }.first?.documentView?.subviews.first as? GhosttyNSView,
            "Expected the terminal's GhosttyNSView"
        )
        XCTAssertTrue(window.makeFirstResponder(surfaceView))
        // keyDown drops keys (and requests recovery) until Ghostty's surface exists.
        XCTAssertTrue(
            waitUntil(timeout: 5) { panel.surface.surface != nil },
            "Expected the runtime Ghostty surface before sending keys"
        )
        XCTAssertTrue(
            AppDelegate.shared?.workspaceFor(tabId: workspace.id) === workspace,
            "The surface must resolve its workspace through AppDelegate.shared, as keyDown does"
        )
        try body(Harness(workspace: workspace, panelId: panel.id, surfaceView: surfaceView, window: window))
    }

    private func key(_ chars: String, ignoring: String? = nil, keyCode: UInt16, _ flags: NSEvent.ModifierFlags = [], window: NSWindow) throws -> NSEvent {
        try XCTUnwrap(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, characters: chars,
            charactersIgnoringModifiers: ignoring ?? chars, isARepeat: false, keyCode: keyCode
        ))
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    func testEscInARunningClaudePaneQueuesOneCheckAndCtrlCDoesNotQueueASecond() throws {
        try withHarness { harness in
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panelId, lifecycle: .running)

            harness.surfaceView.keyDown(with: try key("\u{1b}", keyCode: 53, window: harness.window))

            XCTAssertTrue(
                waitUntil(timeout: 1) { harness.workspace.pendingClaudeInterruptCheckTokens[harness.panelId] != nil },
                "Esc in a running Claude pane must queue the transcript check"
            )
            let token = harness.workspace.pendingClaudeInterruptCheckTokens[harness.panelId]
            harness.surfaceView.keyDown(with: try key("\u{3}", ignoring: "c", keyCode: 8, .control, window: harness.window))
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
            XCTAssertEqual(
                harness.workspace.pendingClaudeInterruptCheckTokens[harness.panelId], token,
                "A second interrupt key while the check is pending must not queue another"
            )
        }
    }

    func testCtrlCInARunningClaudePaneQueuesACheck() throws {
        try withHarness { harness in
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panelId, lifecycle: .running)

            harness.surfaceView.keyDown(with: try key("\u{3}", ignoring: "c", keyCode: 8, .control, window: harness.window))

            XCTAssertTrue(waitUntil(timeout: 1) { harness.workspace.pendingClaudeInterruptCheckTokens[harness.panelId] != nil })
        }
    }

    func testOrdinaryKeysAndIdlePanesQueueNothing() throws {
        try withHarness { harness in
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panelId, lifecycle: .running)
            harness.surfaceView.keyDown(with: try key("a", keyCode: 0, window: harness.window))
            harness.surfaceView.keyDown(with: try key("\u{4}", ignoring: "d", keyCode: 2, .control, window: harness.window))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            XCTAssertNil(harness.workspace.pendingClaudeInterruptCheckTokens[harness.panelId], "Only Esc and Ctrl+C interrupt Claude")

            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panelId, lifecycle: .idle)
            harness.surfaceView.keyDown(with: try key("\u{1b}", keyCode: 53, window: harness.window))
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
            XCTAssertNil(harness.workspace.pendingClaudeInterruptCheckTokens[harness.panelId], "An idle pane has no turn to interrupt")

            // Control: the same pane and key do queue once the turn is open,
            // so the nil results above are not keys lost before the hook.
            harness.workspace.setAgentLifecycle(key: "claude_code", panelId: harness.panelId, lifecycle: .running)
            harness.surfaceView.keyDown(with: try key("\u{1b}", keyCode: 53, window: harness.window))
            XCTAssertTrue(waitUntil(timeout: 1) { harness.workspace.pendingClaudeInterruptCheckTokens[harness.panelId] != nil })
        }
    }
}
