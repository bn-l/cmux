import CmuxWorkspaces
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class PiVaultAgentPersistenceTests: XCTestCase {
    func testRegisteredAgentTemplateFailsClosedWhenPlaceholderIsUnavailable() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --cwd {{cwd}} --session {{sessionId}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-123",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: nil,
            registrationOverride: registration
        )

        XCTAssertNil(command)
    }

    func testRegisteredAgentTemplateUsesExplicitWorkingDirectoryForCWDPlaceholder() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --cwd {{cwd}} --session {{sessionId}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-123",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/tmp/acme",
            registrationOverride: registration,
            includeWorkingDirectoryPrefix: false
        )

        XCTAssertEqual(command, "'acme-agent' '--cwd' '/tmp/acme' '--session' 'session-123'")
    }

    func testRegisteredAgentTemplatePreservesCWDArgumentWithWorkingDirectoryPrefix() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --cwd {{cwd}} --session {{sessionId}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-123",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/tmp/acme",
            registrationOverride: registration
        )

        XCTAssertEqual(
            command,
            "cd -- '/tmp/acme' 2>/dev/null || [ ! -d '/tmp/acme' ] && 'acme-agent' '--cwd' '/tmp/acme' '--session' 'session-123'"
        )
    }

    func testRegisteredAgentTemplateDoesNotExpandPlaceholdersInsideReplacementValues() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}} --cwd {{cwd}}",
            cwd: .preserve
        )

        let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-{{cwd}}",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: nil,
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/tmp/acme",
            registrationOverride: registration,
            includeWorkingDirectoryPrefix: false
        )

        XCTAssertEqual(command, "'acme-agent' '--session' 'session-{{cwd}}' '--cwd' '/tmp/acme'")
    }

    func testBuiltInGrokRegistrationUsesNativeSessionDirectory() {
        let registration = CmuxVaultAgentRegistration.builtInGrok

        XCTAssertEqual(registration.id, "grok")
        XCTAssertEqual(registration.sessionIdSource, .grokSessionDirectory)
        XCTAssertEqual(registration.sessionDirectory, "~/.grok/sessions")
        XCTAssertEqual(registration.detect.processNames, ["grok", "grok-macos-aarch64", "grok-macos-aarch"])
        XCTAssertTrue(registration.detect.argvContains.isEmpty)
    }

    func testRegisteredAgentCWDIgnoreSuppressesResumeWorkingDirectory() {
        let registration = CmuxVaultAgentRegistration(
            id: "acme-agent",
            name: "Acme Agent",
            detect: CmuxVaultAgentDetectRule(processName: "acme-agent"),
            sessionIdSource: .argvOption("--session"),
            resumeCommand: "acme-agent --session {{sessionId}}",
            cwd: .ignore
        )
        let command = AgentResumeCommandBuilder.resumeShellCommand(
            kind: .custom("acme-agent"),
            sessionId: "session-123",
            launchCommand: AgentLaunchCommandSnapshot(
                launcher: "acme-agent",
                executablePath: nil,
                arguments: ["acme-agent"],
                workingDirectory: "/tmp/acme",
                environment: nil,
                capturedAt: nil,
                source: "test"
            ),
            workingDirectory: "/tmp/acme",
            registrationOverride: registration
        )

        XCTAssertEqual(command, "'acme-agent' '--session' 'session-123'")
    }

    func testBuiltInPiRegistrationUsesBrandedIconAsset() {
        XCTAssertEqual(CmuxVaultAgentRegistration.builtInPi.iconAssetName, "AgentIcons/Pi")
    }

    func testBuiltInAntigravityRegistrationUsesBrandedIconAsset() {
        XCTAssertEqual(CmuxVaultAgentRegistration.builtInAntigravity.iconAssetName, "AgentIcons/Antigravity")
        XCTAssertEqual(CmuxVaultAgentRegistration.builtInAntigravity.detect.processNames, ["agy", "antigravity"])
    }

    func testPiVaultAgentSnapshotRoundTripBuildsTargetedSessionCommand() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-pi-vault-agent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sessionPath = tempDir
            .appendingPathComponent("--tmp-pi repo--", isDirectory: true)
            .appendingPathComponent("2026-05-05T12-00-00-000Z_018f2b35-7c75-7e1a-a6ff-cc1d5f9f0000.jsonl")
            .path
        let panelId = UUID(uuidString: "3D4D5F4B-CA09-4E5C-A65E-8423D7F4BEA0")!
        let piKind = try XCTUnwrap(RestorableAgentKind(rawValue: "pi"))

        var snapshot = makeSnapshot()
        snapshot.windows[0].tabManager.workspaces[0].focusedPanelId = panelId
        snapshot.windows[0].tabManager.workspaces[0].layout = .pane(
            SessionPaneLayoutSnapshot(panelIds: [panelId], selectedPanelId: panelId)
        )
        snapshot.windows[0].tabManager.workspaces[0].panels = [
            SessionPanelSnapshot(
                id: panelId,
                type: .terminal,
                title: "Pi",
                customTitle: nil,
                directory: "/tmp/pi repo",
                isPinned: false,
                isManuallyUnread: false,
                gitBranch: nil,
                listeningPorts: [],
                ttyName: "ttys001",
                terminal: SessionTerminalPanelSnapshot(
                    workingDirectory: "/tmp/pi repo",
                    scrollback: nil,
                    agent: SessionRestorableAgentSnapshot(
                        kind: piKind,
                        sessionId: sessionPath,
                        workingDirectory: "/tmp/pi repo",
                        launchCommand: AgentLaunchCommandSnapshot(
                            launcher: "pi",
                            executablePath: "/opt/homebrew/bin/pi",
                            arguments: ["/opt/homebrew/bin/pi", "--session-dir", tempDir.path, "--session", "old-session", "--continue"],
                            workingDirectory: "/tmp/pi repo",
                            environment: ["PI_CODING_AGENT_SESSION_DIR": tempDir.path],
                            capturedAt: 1_777_777_777,
                            source: "process"
                        ),
                        registration: CmuxVaultAgentRegistration.builtInPi
                    ),
                    tmuxStartCommand: nil
                ),
                browser: nil,
                markdown: nil,
                filePreview: nil,
                rightSidebarTool: nil
            )
        ]

        let snapshotURL = tempDir.appendingPathComponent("session.json", isDirectory: false)
        let store = SessionSnapshotRepository<AppSessionSnapshot>(
            schemaVersion: SessionSnapshotSchema.currentVersion,
            bundleIdentifier: "com.cmuxterm.tests"
        )
        XCTAssertTrue(store.save(snapshot, fileURL: snapshotURL))
        let loadedAgent = try XCTUnwrap(
            store.load(fileURL: snapshotURL)?.windows.first?
                .tabManager.workspaces.first?.panels.first?.terminal?.agent
        )

        XCTAssertEqual(loadedAgent.kind.rawValue, "pi")
        XCTAssertEqual(loadedAgent.sessionId, sessionPath)
        XCTAssertEqual(
            loadedAgent.resumeCommand,
            TerminalStartupWorkingDirectoryPrefix.prefix(
                "'env' 'PI_CODING_AGENT_SESSION_DIR=\(tempDir.path)' '/opt/homebrew/bin/pi' '--session' '\(sessionPath)' '--session-dir' '\(tempDir.path)'",
                workingDirectory: "/tmp/pi repo"
            )
        )
    }

    private func makeSnapshot() -> AppSessionSnapshot {
        let workspace = SessionWorkspaceSnapshot(
            processTitle: "Terminal",
            customTitle: "Restored",
            customColor: nil,
            isPinned: true,
            currentDirectory: "/tmp",
            focusedPanelId: nil,
            layout: .pane(SessionPaneLayoutSnapshot(panelIds: [], selectedPanelId: nil)),
            panels: [],
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil
        )
        return AppSessionSnapshot(
            version: SessionSnapshotSchema.currentVersion,
            createdAt: Date().timeIntervalSince1970,
            windows: [
                SessionWindowSnapshot(
                    frame: SessionRectSnapshot(x: 10, y: 20, width: 900, height: 700),
                    display: nil,
                    tabManager: SessionTabManagerSnapshot(selectedWorkspaceIndex: 0, workspaces: [workspace]),
                    sidebar: SessionSidebarSnapshot(isVisible: true, selection: .tabs, width: 240)
                )
            ]
        )
    }
}
