import Foundation
import CmuxCore
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite struct SessionPersistenceResumeBindingTests {
    @Test func agentHookSurfaceResumeStartupInputPreservesCustomAbsoluteAgentExecutable() throws {
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'/opt/company/bin/codex' 'resume' 'session-custom-cli'",
            checkpointId: "session-custom-cli",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains("'/opt/company/bin/codex'"), "\(startupInput)")
    }

    @Test func decodingAgentHookBindingRewritesPersistedPATHManagedAgentExecutable() throws {
        let executablePath = Self.homeManagedExecutablePath(
            executableName: "claude",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let json = """
        {
          "kind": "claude",
          "command": "{ cd -- '/tmp/project' 2>/dev/null || [ ! -d '/tmp/project' ]; } && '\(executablePath)' '--resume' 'session-moved-cli' '--chrome'",
          "cwd": "/tmp/project",
          "checkpointId": "session-moved-cli",
          "source": "agent-hook",
          "autoResume": true,
          "updatedAt": 123
        }
        """
        let binding = try JSONDecoder().decode(SurfaceResumeBindingSnapshot.self, from: Data(json.utf8))
        let startupInput = try #require(binding.startupInput)

        #expect(binding.command.contains(executablePath), "\(binding.command)")
        #expect(startupInput.contains("/bin/sh -c"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CLAUDE_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("--resume"), "\(startupInput)")
        #expect(!startupInput.contains(executablePath), "\(startupInput)")
    }

    @Test func legacyAgentHookBindingWithoutKindRewritesPersistedPATHManagedAgentExecutable() throws {
        let executablePath = Self.homeManagedExecutablePath(
            executableName: "codex",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let json = """
        {
          "command": "'\(executablePath)' 'resume' 'session-legacy-cli'",
          "checkpointId": "session-legacy-cli",
          "source": "agent-hook",
          "autoResume": true,
          "updatedAt": 123
        }
        """
        let binding = try JSONDecoder().decode(SurfaceResumeBindingSnapshot.self, from: Data(json.utf8))
        let startupInput = try #require(binding.startupInput)

        #expect(binding.kind == nil)
        #expect(binding.command.contains(executablePath), "\(binding.command)")
        #expect(startupInput.contains("codex 'resume' 'session-legacy-cli'"), "\(startupInput)")
        #expect(!startupInput.contains(executablePath), "\(startupInput)")
    }

    @Test func agentHookBindingRewritesSupportedLocalManagedExecutablePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-stale-managed-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let executablePaths = [
            Self.localManagedExecutablePath(root: root, executableName: "codex", ".fnm", "current", "bin"),
            "/tmp/cmux-cli-shims/\(UUID().uuidString)/codex",
            Self.localManagedExecutablePath(
                root: root,
                executableName: "codex",
                "Library",
                "Application Support",
                "fnm",
                "node-versions",
                "v24.2.0",
                "installation",
                "bin"
            ),
            Self.localManagedExecutablePath(
                root: root,
                executableName: "codex",
                ".local",
                "share",
                "fnm",
                "node-versions",
                "v24.2.0",
                "installation",
                "bin"
            ),
            Self.localManagedExecutablePath(root: root, executableName: "codex", ".local", "share", "mise", "shims"),
        ]

        for executablePath in executablePaths {
            let binding = SurfaceResumeBindingSnapshot(
                kind: "codex",
                command: "'\(executablePath)' 'resume' 'session-managed-cli'",
                checkpointId: "session-managed-cli",
                source: "agent-hook",
                autoResume: true
            )

            let startupInput = try #require(binding.startupInput)
            #expect(startupInput.contains("codex 'resume' 'session-managed-cli'"), "\(startupInput)")
            #expect(!startupInput.contains(executablePath), "\(startupInput)")
        }
    }

    @Test func agentHookBindingWithDirectEnvironmentAssignmentRewritesMovedExecutable() throws {
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "codex",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "CMUX_TRACE=1 '\(staleExecutablePath)' 'resume' 'session-env-cli'",
            checkpointId: "session-env-cli",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains("CMUX_TRACE=1 codex 'resume' 'session-env-cli'"), "\(startupInput)")
        #expect(!startupInput.contains(staleExecutablePath), "\(startupInput)")
    }

    @Test func agentHookBindingWithQuotedEnvAssignmentRewritesMovedExecutable() throws {
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "codex",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "env 'CMUX_TRACE=1' '\(staleExecutablePath)' 'resume' 'session-quoted-env-cli'",
            checkpointId: "session-quoted-env-cli",
            source: "agent-hook",
            autoResume: true
        )
        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains("env 'CMUX_TRACE=1' codex 'resume' 'session-quoted-env-cli'"), "\(startupInput)")
        #expect(!startupInput.contains(staleExecutablePath), "\(startupInput)")
    }

    @Test func agentHookClaudeBindingWithDirectEnvironmentAssignmentPreservesAssignmentSyntax() throws {
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "claude",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "CMUX_TRACE='bar baz' '\(staleExecutablePath)' '--resume' 'session-env-cli'",
            checkpointId: "session-env-cli",
            source: "agent-hook",
            autoResume: true
        )
        let startupInput = try #require(binding.startupInput)

        #expect(startupInput.contains("/bin/sh -c"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CLAUDE_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_TRACE="), "\(startupInput)")
        #expect(startupInput.contains("bar baz"), "\(startupInput)")
        #expect(!startupInput.contains(staleExecutablePath), "\(startupInput)")
    }

    @Test func agentHookClaudeBindingWithShellOperatorKeepsOriginalCommandShape() throws {
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "claude",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let redirection = "1>/tmp/cmux-claude-resume.log"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "claude",
            command: "'\(staleExecutablePath)' '--resume' 'session-operator-cli' \(redirection) && echo done",
            checkpointId: "session-operator-cli",
            source: "agent-hook",
            autoResume: true
        )
        let startupInput = try #require(binding.startupInput)

        #expect(binding.command.contains("&& echo done"), "\(binding.command)")
        #expect(binding.command.contains(staleExecutablePath), "\(binding.command)")
        #expect(startupInput.contains("/bin/sh -c"), "\(startupInput)")
        #expect(startupInput.contains("CMUX_CLAUDE_WRAPPER_SHIM"), "\(startupInput)")
        #expect(startupInput.contains("session-operator-cli \(redirection) && echo done"), "\(startupInput)")
        #expect(!startupInput.contains(staleExecutablePath), "\(startupInput)")
    }

    @Test func agentHookBindingPreservesRemoteManagedExecutablePath() throws {
        let remoteExecutablePath = "/home/me/.nvm/versions/node/v24.2.0/bin/codex"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'\(remoteExecutablePath)' 'resume' 'session-remote-cli'",
            checkpointId: "session-remote-cli",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)
        #expect(startupInput.contains("'\(remoteExecutablePath)' 'resume' 'session-remote-cli'"), "\(startupInput)")
    }

    @Test func remoteStartupInputPreservesLocalLookingManagedExecutablePaths() throws {
        let executablePaths = [
            Self.homeManagedExecutablePath(
                executableName: "codex",
                ".nvm",
                "versions",
                "node",
                "cmux-missing-\(UUID().uuidString)",
                "bin"
            ),
            "/tmp/cmux-cli-shims/\(UUID().uuidString)/codex",
        ]

        for executablePath in executablePaths {
            let binding = SurfaceResumeBindingSnapshot(
                kind: "codex",
                command: "'\(executablePath)' 'resume' 'session-remote-local-looking-cli'",
                checkpointId: "session-remote-local-looking-cli",
                source: "agent-hook",
                autoResume: true
            )

            let startupInput = try #require(binding.startupInputWithLauncherScript(
                allowLauncherScript: false,
                repairPortableAgentExecutable: false
            ))
            #expect(
                startupInput.contains("'\(executablePath)' 'resume' 'session-remote-local-looking-cli'"),
                "\(startupInput)"
            )
        }
    }

    @Test @MainActor func remoteWorkspaceLocalTerminalResumeBindingUsesLocalRepair() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-local-resume-binding-\(UUID().uuidString)", isDirectory: true)
        let localDirectoryURL = root.appendingPathComponent("local repo", isDirectory: true)
        let binURL = root.appendingPathComponent("bin", isDirectory: true)
        let codexOutputURL = root.appendingPathComponent("codex-output.txt", isDirectory: false)
        try fileManager.createDirectory(at: localDirectoryURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: binURL, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCodexURL = binURL.appendingPathComponent("codex", isDirectory: false)
        try """
        #!/bin/sh
        printf '%s|%s\\n' "$PWD" "$*" > "$CMUX_FAKE_CODEX_OUTPUT"
        """.write(to: fakeCodexURL, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodexURL.path)

        let suiteName = "cmux-session-resume-binding-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: AgentSessionAutoResumeSettings.autoResumeAgentSessionsKey)

        let remoteWorkspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        remoteWorkspace.setCustomTitle("Remote Workspace With Local Resume Binding")
        remoteWorkspace.configureRemoteConnection(
            WorkspaceRemoteConfiguration(
                destination: "dev@example.com",
                port: 2222,
                identityFile: nil,
                sshOptions: [
                    "StrictHostKeyChecking=accept-new",
                ],
                localProxyPort: nil,
                relayPort: nil,
                relayID: nil,
                relayToken: nil,
                localSocketPath: nil,
                terminalStartupCommand: "ssh -p 2222 dev@example.com",
                preserveAfterTerminalExit: false
            ),
            autoConnect: false
        )
        let paneId = try #require(remoteWorkspace.bonsplitController.allPaneIds.first)
        let localDirectory = localDirectoryURL.path
        let localPanel = try #require(remoteWorkspace.newTerminalSurface(
            inPane: paneId,
            focus: true,
            workingDirectory: localDirectory,
            suppressWorkspaceRemoteStartupCommand: true
        ))
        remoteWorkspace.setPanelCustomTitle(panelId: localPanel.id, title: "Local Resume Shell")
        let staleExecutablePath = Self.homeManagedExecutablePath(
            executableName: "codex",
            ".nvm",
            "versions",
            "node",
            "cmux-missing-\(UUID().uuidString)",
            "bin"
        )
        let oversizedArgument = String(
            repeating: "x",
            count: SurfaceResumeBindingSnapshot.maxInlineStartupInputBytes + 1
        )
        let quotedDirectory = "'\(localDirectory)'"
        #expect(remoteWorkspace.setSurfaceResumeBinding(
            SurfaceResumeBindingSnapshot(
                name: "Codex",
                kind: "codex",
                command: "{ cd -- \(quotedDirectory) 2>/dev/null || [ ! -d \(quotedDirectory) ]; } && "
                    + "'\(staleExecutablePath)' 'resume' 'session-local-resume' '\(oversizedArgument)'",
                cwd: localDirectory,
                checkpointId: "session-local-resume",
                source: "agent-hook",
                autoResume: true,
                updatedAt: 10
            ),
            panelId: localPanel.id
        ))

        let snapshot = remoteWorkspace.sessionSnapshot(includeScrollback: false)
        let persistedLocalPanel = try #require(snapshot.panels.first {
            $0.customTitle == "Local Resume Shell"
        })
        #expect(persistedLocalPanel.terminal?.isRemoteTerminal == false)
        #expect(persistedLocalPanel.terminal?.resumeBinding?.command.contains(staleExecutablePath) == true)

        let restoredWorkspace = Workspace(agentSessionAutoResumeDefaults: defaults)
        restoredWorkspace.restoreSessionSnapshot(snapshot)
        let restoredLocalPanel = try #require(
            restoredWorkspace.sessionSnapshot(includeScrollback: false)
                .panels.first { $0.customTitle == "Local Resume Shell" }
        )
        let restoredPanel = try #require(restoredWorkspace.terminalPanel(for: restoredLocalPanel.id))
        let restoredCommand = try #require(restoredPanel.surface.debugInitialCommand())
        #expect(restoredPanel.surface.debugInitialInputForTesting() == nil)
        #expect(restoredPanel.requestedWorkingDirectory == nil)
        let launcherScriptPath = try launcherScriptPath(from: restoredCommand)
        let launcherEnvironment = try makeOhMyZshLauncherEnvironment(
            root: root,
            integrationDir: shellIntegrationDirectory(),
            pathPrefix: binURL.path,
            codexShimURL: fakeCodexURL,
            codexOutputURL: codexOutputURL
        )
        try runLauncherUntilOutput(
            scriptPath: launcherScriptPath,
            environment: launcherEnvironment,
            outputURL: codexOutputURL
        )
        let codexOutput = try String(contentsOf: codexOutputURL, encoding: .utf8)
        #expect(codexOutput.contains("\(localDirectory)|resume session-local-resume"), "\(codexOutput)")
        #expect(!codexOutput.contains(staleExecutablePath), "\(codexOutput)")
    }

    @Test func agentHookSurfaceResumeStartupInputPreservesExistingPATHManagedAgentExecutable() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-existing-agent-\(UUID().uuidString)", isDirectory: true)
        let executable = root
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
            .appendingPathComponent("v24.2.0", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        try fileManager.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: executable, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        defer { try? fileManager.removeItem(at: root) }

        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "'\(executable.path)' 'resume' 'session-existing-cli'",
            checkpointId: "session-existing-cli",
            source: "agent-hook",
            autoResume: true
        )

        let startupInput = try #require(binding.startupInput)
        #expect(startupInput.contains("'\(executable.path)'"), "\(startupInput)")
    }

    @Test func agentHookSurfaceResumeStartupInputFallsBackWhenRecordedAgentExecutableMoved() throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-surface-resume-moved-agent-\(UUID().uuidString)", isDirectory: true)
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        let cwd = root.appendingPathComponent("repo", isDirectory: true)
        let movedExecutable = root
            .appendingPathComponent(".nvm", isDirectory: true)
            .appendingPathComponent("versions", isDirectory: true)
            .appendingPathComponent("node", isDirectory: true)
            .appendingPathComponent("v24.2.0", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent("codex", isDirectory: false)
        let outputURL = root.appendingPathComponent("codex-output.txt", isDirectory: false)
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: cwd, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }

        let fakeCodex = bin.appendingPathComponent("codex", isDirectory: false)
        try """
        #!/bin/sh
        printf '%s|%s\\n' "$PWD" "$*" > "$CMUX_FAKE_CODEX_OUTPUT"
        """.write(to: fakeCodex, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeCodex.path)

        let quotedCwd = "'\(cwd.path)'"
        let binding = SurfaceResumeBindingSnapshot(
            kind: "codex",
            command: "{ cd -- \(quotedCwd) 2>/dev/null || [ ! -d \(quotedCwd) ]; } && "
                + "'\(movedExecutable.path)' 'resume' 'session-moved-cli' '--yolo'",
            cwd: cwd.path,
            checkpointId: "session-moved-cli",
            source: "agent-hook",
            autoResume: true
        )
        let startupInput = try #require(binding.startupInput)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-fc", startupInput]
        process.environment = [
            "PATH": "\(bin.path):/usr/bin:/bin",
            "CMUX_FAKE_CODEX_OUTPUT": outputURL.path,
        ]
        let stderr = Pipe()
        process.standardError = stderr

        try runWithBoundedWait(process, shellDescription: "zsh -fc")

        let errorText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        #expect(process.terminationStatus == 0, "\(errorText)")

        let output = try String(contentsOf: outputURL, encoding: .utf8)
        #expect(output == "\(cwd.path)|resume session-moved-cli -c check_for_update_on_startup=false --yolo\n")
        #expect(!startupInput.contains(movedExecutable.path), "\(startupInput)")
    }

    private struct ResumeShellTimeout: Error, CustomStringConvertible {
        let shellDescription: String
        let timeout: TimeInterval

        var description: String {
            "Resume shell (\(shellDescription)) did not exit within \(Int(timeout))s; treating as hung."
        }
    }

    private func runWithBoundedWait(
        _ process: Process,
        shellDescription: String,
        timeout: TimeInterval = 30
    ) throws {
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            _ = exited.wait(timeout: .now() + 2)
            throw ResumeShellTimeout(shellDescription: shellDescription, timeout: timeout)
        }
    }

    private func runLauncherUntilOutput(
        scriptPath: String,
        environment: [String: String],
        outputURL: URL,
        timeout: TimeInterval = 10
    ) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [scriptPath]
        process.environment = environment
        let stderr = Pipe()
        process.standardOutput = FileHandle.nullDevice
        process.standardError = stderr

        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let output = try? String(contentsOf: outputURL, encoding: .utf8),
               !output.isEmpty {
                if process.isRunning {
                    process.terminate()
                    process.waitUntilExit()
                }
                return
            }
            _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
        let errorText = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        Issue.record("Launcher did not produce Codex output within \(Int(timeout))s. stderr: \(errorText)")
        throw ResumeShellTimeout(shellDescription: "/bin/zsh \(scriptPath)", timeout: timeout)
    }

    private func launcherScriptPath(from command: String) throws -> String {
        let words = TerminalStartupWorkingDirectoryPrefix.shellWordRanges(command).map(\.value)
        #expect(words.first == "/bin/zsh", "\(command)")
        return try #require(words.dropFirst().first, "Expected /bin/zsh launcher script command, saw: \(command)")
    }

    private func shellIntegrationDirectory() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/shell-integration", isDirectory: true)
    }

    private func makeOhMyZshLauncherEnvironment(
        root: URL,
        integrationDir: URL,
        pathPrefix: String,
        codexShimURL: URL,
        codexOutputURL: URL
    ) throws -> [String: String] {
        let homeURL = root.appendingPathComponent("home", isDirectory: true)
        let userZdotdirURL = root.appendingPathComponent("zdotdir", isDirectory: true)
        let ohMyZshURL = root.appendingPathComponent("oh-my-zsh", isDirectory: true)
        try FileManager.default.createDirectory(at: homeURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: userZdotdirURL, withIntermediateDirectories: true)
        try writeOhMyZshFixture(at: ohMyZshURL)
        try "\n".write(
            to: userZdotdirURL.appendingPathComponent(".zshenv", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try """
        export ZSH="\(ohMyZshURL.path)"
        export ZSH_DISABLE_COMPFIX=true
        export DISABLE_AUTO_UPDATE=true
        ZSH_THEME=""
        plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
        source "$ZSH/oh-my-zsh.sh"
        """.write(
            to: userZdotdirURL.appendingPathComponent(".zshrc", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        return [
            "HOME": homeURL.path,
            "TERM": "xterm-256color",
            "SHELL": "/bin/zsh",
            "USER": NSUserName(),
            "PATH": "\(pathPrefix):/usr/bin:/bin",
            "ZDOTDIR": integrationDir.path,
            "CMUX_ZSH_ZDOTDIR": userZdotdirURL.path,
            "CMUX_SHELL_INTEGRATION": "1",
            "CMUX_SHELL_INTEGRATION_DIR": integrationDir.path,
            "CMUX_ZSH_RESTORE_TERM": "xterm-256color",
            "CMUX_CODEX_WRAPPER_SHIM": codexShimURL.path,
            "CMUX_FAKE_CODEX_OUTPUT": codexOutputURL.path,
            "ZSH_DISABLE_COMPFIX": "true",
            "DISABLE_AUTO_UPDATE": "true",
        ]
    }

    private func writeOhMyZshFixture(at root: URL) throws {
        let customPluginRoot = root.appendingPathComponent("custom/plugins", isDirectory: true)
        let autosuggestionsURL = customPluginRoot
            .appendingPathComponent("zsh-autosuggestions", isDirectory: true)
        let syntaxHighlightingURL = customPluginRoot
            .appendingPathComponent("zsh-syntax-highlighting", isDirectory: true)
        try FileManager.default.createDirectory(at: autosuggestionsURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: syntaxHighlightingURL, withIntermediateDirectories: true)

        try """
        autoload -Uz add-zsh-hook
        for plugin in $plugins; do
          plugin_file="$ZSH/custom/plugins/$plugin/$plugin.plugin.zsh"
          [[ -r "$plugin_file" ]] && source "$plugin_file"
        done
        """.write(
            to: root.appendingPathComponent("oh-my-zsh.sh", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try """
        autoload -Uz add-zsh-hook
        _cmux_test_autosuggest_precmd() { :; }
        _cmux_test_autosuggest_preexec() { :; }
        add-zsh-hook precmd _cmux_test_autosuggest_precmd
        add-zsh-hook preexec _cmux_test_autosuggest_preexec
        _cmux_test_autosuggest_self_insert() { zle .self-insert }
        zle -N self-insert _cmux_test_autosuggest_self_insert
        """.write(
            to: autosuggestionsURL.appendingPathComponent("zsh-autosuggestions.plugin.zsh", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
        try """
        _cmux_test_syntax_highlighting_line_init() { :; }
        _cmux_test_syntax_highlighting_line_finish() { :; }
        zle -N zle-line-init _cmux_test_syntax_highlighting_line_init
        zle -N zle-line-finish _cmux_test_syntax_highlighting_line_finish
        """.write(
            to: syntaxHighlightingURL.appendingPathComponent("zsh-syntax-highlighting.plugin.zsh", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )
    }

    private static func homeManagedExecutablePath(executableName: String, _ components: String...) -> String {
        localManagedExecutablePath(root: FileManager.default.homeDirectoryForCurrentUser, executableName: executableName, components)
    }

    private static func localManagedExecutablePath(
        root: URL,
        executableName: String,
        _ components: String...
    ) -> String {
        localManagedExecutablePath(root: root, executableName: executableName, components)
    }

    private static func localManagedExecutablePath(
        root: URL,
        executableName: String,
        _ components: [String]
    ) -> String {
        var directory = root
        for component in components {
            directory.appendPathComponent(component, isDirectory: true)
        }
        return directory.appendingPathComponent(executableName, isDirectory: false).path
    }
}

/// Regression coverage for the cross-project session/notification mix-up after restart.
///
/// Workspace ids are re-minted on every launch while panel ids persist, so after a
/// restart every `(workspaceId, panelId)` lookup misses and falls back to a panel-id-only
/// one. Ungated, that fallback served another project's agent record for the same panel
/// id — panes came back auto-resuming a sibling repo's conversation, and its hooks then
/// drove that pane's status pill, notifications and resume binding.
@Suite(.serialized)
struct CrossProjectAgentSessionIdentityTests {
    // MARK: - Directory affinity

    @Test func directoryAffinityAcceptsSameTreeAndRejectsSiblingProjects() {
        #expect(AgentSessionDirectoryAffinity.isAffine("/tmp/projA", "/tmp/projA"))
        #expect(AgentSessionDirectoryAffinity.isAffine("/tmp/projA/pkg", "/tmp/projA"))
        #expect(AgentSessionDirectoryAffinity.isAffine("/tmp/projA", "/tmp/projA/pkg"))
        #expect(AgentSessionDirectoryAffinity.isAffine("/tmp/projA/", "/tmp/projA"))
        #expect(!AgentSessionDirectoryAffinity.isAffine("/tmp/projA", "/tmp/projB"))
        // "projA2" must not read as inside "projA".
        #expect(!AgentSessionDirectoryAffinity.isAffine("/tmp/projA2", "/tmp/projA"))
        // Fails closed when either side is unknown.
        #expect(!AgentSessionDirectoryAffinity.isAffine(nil, "/tmp/projA"))
        #expect(!AgentSessionDirectoryAffinity.isAffine("/tmp/projA", nil))
        #expect(!AgentSessionDirectoryAffinity.isAffine("  ", "/tmp/projA"))
    }

    // MARK: - RestorableAgentSessionIndex panel-id fallback

    @Test func panelIdFallbackServesOnlyTheDirectoryAffineProjectRecord() throws {
        let fixture = try HookStoreFixture(prefix: "cmux-affinity-fallback")
        defer { fixture.tearDown() }

        let panelId = UUID()
        let projectA = try fixture.makeProjectDirectory(named: "projA")
        let projectB = try fixture.makeProjectDirectory(named: "projB")
        let sessionA = "aaaaaaaa-1111-1111-1111-111111111111"
        let sessionB = "bbbbbbbb-2222-2222-2222-222222222222"

        try fixture.writeCodexHookStore(sessions: [
            sessionA: fixture.record(
                sessionId: sessionA,
                workspaceId: UUID(),
                panelId: panelId,
                cwd: projectA,
                updatedAt: 10
            ),
            sessionB: fixture.record(
                sessionId: sessionB,
                workspaceId: UUID(),
                panelId: panelId,
                cwd: projectB,
                updatedAt: 20
            ),
        ])
        let index = fixture.loadIndex()

        // A relaunched workspace has a brand-new id, so only the panel-id fallback can
        // resolve. Each project's pane must get its OWN record back.
        let relaunchedWorkspaceId = UUID()
        #expect(
            index.snapshot(
                workspaceId: relaunchedWorkspaceId,
                panelId: panelId,
                directory: projectA
            )?.sessionId == sessionA
        )
        #expect(
            index.snapshot(
                workspaceId: relaunchedWorkspaceId,
                panelId: panelId,
                directory: projectB
            )?.sessionId == sessionB
        )
        // A pane in a third project gets nothing rather than a stranger's session.
        let projectC = try fixture.makeProjectDirectory(named: "projC")
        #expect(
            index.snapshot(
                workspaceId: relaunchedWorkspaceId,
                panelId: panelId,
                directory: projectC
            ) == nil
        )
        // Neither record has a running process, so with no directory to check there is no
        // proof of ownership left and the fallback is refused.
        #expect(
            index.snapshot(workspaceId: relaunchedWorkspaceId, panelId: panelId, directory: nil) == nil
        )
    }

    /// A workspace move re-keys a pane while its agent keeps running. The running process
    /// carries this panel id in its own environment, which is proof of ownership that a
    /// dead hook record can never have — so the fallback must still serve it even though
    /// the caller has no directory to compare.
    @Test func panelIdFallbackAcceptsLiveProcessAttributionWithoutADirectory() throws {
        let entry = RestorableAgentSessionIndex.Entry(
            snapshot: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "live-session",
                workingDirectory: nil,
                launchCommand: nil
            ),
            lifecycle: nil,
            updatedAt: 0,
            processIDs: [4_242],
            agentProcessIDs: [4_242],
            agentProcessIdentities: [:],
            keyedByLiveProcessEnvironment: true
        )
        #expect(RestorableAgentSessionIndex.panelIdFallbackAccepts(entry, directory: nil))
        #expect(RestorableAgentSessionIndex.panelIdFallbackAccepts(entry, directory: "/tmp/anything"))

        // The same attribution without a running process proves nothing: the environment
        // was read from a process that has since exited.
        let exited = RestorableAgentSessionIndex.Entry(
            snapshot: entry.snapshot,
            lifecycle: nil,
            updatedAt: 0,
            processIDs: [],
            agentProcessIDs: [],
            agentProcessIdentities: [:],
            keyedByLiveProcessEnvironment: true
        )
        #expect(!RestorableAgentSessionIndex.panelIdFallbackAccepts(exited, directory: nil))

        // A hook record's panel id is the hook's routing guess, not the agent's own
        // report, so a live pid does NOT excuse it from the directory check.
        let hookRecorded = RestorableAgentSessionIndex.Entry(
            snapshot: SessionRestorableAgentSnapshot(
                kind: .codex,
                sessionId: "hook-session",
                workingDirectory: "/tmp/other-project",
                launchCommand: nil
            ),
            lifecycle: nil,
            updatedAt: 0,
            processIDs: [4_243],
            agentProcessIDs: [4_243],
            agentProcessIdentities: [:]
        )
        #expect(!RestorableAgentSessionIndex.panelIdFallbackAccepts(hookRecorded, directory: "/tmp/my-project"))
        #expect(RestorableAgentSessionIndex.panelIdFallbackAccepts(hookRecorded, directory: "/tmp/other-project"))
    }

    @Test func panelIdFallbackPrefersLiveProcessOverNewerRecord() throws {
        let fixture = try HookStoreFixture(prefix: "cmux-affinity-live-pid")
        defer { fixture.tearDown() }

        let panelId = UUID()
        let project = try fixture.makeProjectDirectory(named: "repo")
        let liveWorkspaceId = UUID()
        let livePID = 4_242
        let liveSession = "cccccccc-3333-3333-3333-333333333333"
        let newerDeadSession = "dddddddd-4444-4444-4444-444444444444"

        var liveRecord = fixture.record(
            sessionId: liveSession,
            workspaceId: liveWorkspaceId,
            panelId: panelId,
            cwd: project,
            updatedAt: 10
        )
        liveRecord["pid"] = livePID
        var deadRecord = fixture.record(
            sessionId: newerDeadSession,
            workspaceId: UUID(),
            panelId: panelId,
            cwd: project,
            updatedAt: 99
        )
        deadRecord["pid"] = 987_654_321
        try fixture.writeCodexHookStore(sessions: [
            liveSession: liveRecord,
            newerDeadSession: deadRecord,
        ])

        let index = fixture.loadIndex(processArgumentsProvider: { pid in
            guard pid == livePID else { return nil }
            return CmuxTopProcessArguments(
                arguments: ["/usr/local/bin/codex"],
                environment: [
                    "CMUX_WORKSPACE_ID": liveWorkspaceId.uuidString,
                    "CMUX_SURFACE_ID": panelId.uuidString,
                ]
            )
        })

        #expect(
            index.snapshot(workspaceId: UUID(), panelId: panelId, directory: project)?.sessionId == liveSession,
            "A running agent must outrank a newer record whose process is gone."
        )
    }

    @Test func panelIdFallbackTieBreaksDeterministically() throws {
        let panelId = UUID()
        let project = "/tmp/cmux-tie-break-repo"
        // Fixed ids so the expected winner is stated, not observed.
        let lowerWorkspaceId = try #require(UUID(uuidString: "00000000-0000-0000-0000-00000000000A"))
        let higherWorkspaceId = try #require(UUID(uuidString: "FFFFFFFF-0000-0000-0000-00000000000B"))

        // Dictionary iteration order varies per process, so an arbitrary winner would
        // make restore resolve differently between launches. Repeat to make an
        // order-dependent implementation fail rather than flake.
        for _ in 0..<32 {
            let index = SurfaceResumeBindingIndex(bindingsByPanel: [
                SurfaceResumeBindingIndex.PanelKey(workspaceId: higherWorkspaceId, panelId: panelId):
                    Self.binding(sessionId: "higher", cwd: project, updatedAt: 7),
                SurfaceResumeBindingIndex.PanelKey(workspaceId: lowerWorkspaceId, panelId: panelId):
                    Self.binding(sessionId: "lower", cwd: project, updatedAt: 7),
            ])
            #expect(
                index.binding(workspaceId: UUID(), panelId: panelId, directory: project)?.checkpointId == "lower"
            )
        }
    }

    // MARK: - SurfaceResumeBindingIndex panel-id fallback

    @Test func resumeBindingPanelFallbackRefusesAnotherProjectsBinding() throws {
        let panelId = UUID()
        let index = SurfaceResumeBindingIndex(bindingsByPanel: [
            SurfaceResumeBindingIndex.PanelKey(workspaceId: UUID(), panelId: panelId):
                Self.binding(sessionId: "other-project", cwd: "/tmp/other-project", updatedAt: 5),
        ])

        #expect(
            index.binding(workspaceId: UUID(), panelId: panelId, directory: "/tmp/my-project") == nil,
            "A binding recorded for another project must not resume in this pane."
        )
        #expect(
            index.binding(workspaceId: UUID(), panelId: panelId, directory: "/tmp/other-project")?
                .checkpointId == "other-project"
        )
    }

    // MARK: - Save-side duplicate session claims

    @Test func snapshotSaveKeepsOneClaimPerAgentSession() throws {
        let sessionId = "eeeeeeee-5555-5555-5555-555555555555"
        let winnerPanelId = try #require(UUID(uuidString: "11111111-1111-1111-1111-111111111111"))
        let loserPanelId = try #require(UUID(uuidString: "22222222-2222-2222-2222-222222222222"))

        let workspace = Self.workspaceSnapshot(
            currentDirectory: "/tmp/real-project",
            panels: [
                // Real owner: the binding's cwd is this pane's own directory.
                Self.terminalPanelSnapshot(
                    id: winnerPanelId,
                    directory: "/tmp/real-project",
                    binding: Self.binding(sessionId: sessionId, cwd: "/tmp/real-project", updatedAt: 10)
                ),
                // Mis-routed duplicate: same session, different pane, newer binding.
                Self.terminalPanelSnapshot(
                    id: loserPanelId,
                    directory: "/tmp/real-project",
                    binding: Self.binding(sessionId: sessionId, cwd: "/tmp/real-project", updatedAt: 99)
                ),
            ]
        )

        let pruned = TabManager.deduplicatingAgentSessionClaims([workspace], restorableAgentIndex: .empty)
        let panels = try #require(pruned.first?.panels)

        // The newest binding wins on `updatedAt`; the point is that exactly one survives.
        let survivors = panels.filter { $0.terminal?.resumeBinding != nil }
        #expect(survivors.count == 1, "Only one pane may claim a session id.")
        let dropped = try #require(panels.first { $0.terminal?.resumeBinding == nil })
        #expect(dropped.terminal?.agent == nil)
        #expect(dropped.terminal?.wasAgentRunning == false)
    }

    @Test func snapshotSavePrefersTheDirectoryAffineClaimant() throws {
        let sessionId = "ffffffff-6666-6666-6666-666666666666"
        let affinePanelId = try #require(UUID(uuidString: "33333333-3333-3333-3333-333333333333"))
        let strayPanelId = try #require(UUID(uuidString: "44444444-4444-4444-4444-444444444444"))

        let workspaces = [
            Self.workspaceSnapshot(
                currentDirectory: "/tmp/owner-project",
                panels: [
                    Self.terminalPanelSnapshot(
                        id: affinePanelId,
                        directory: "/tmp/owner-project",
                        binding: Self.binding(sessionId: sessionId, cwd: "/tmp/owner-project", updatedAt: 1)
                    ),
                ]
            ),
            // A different WORKSPACE holding the same session with a foreign cwd — the
            // shape a poisoned hook record produced. Newer, so `updatedAt` alone would
            // pick it.
            Self.workspaceSnapshot(
                currentDirectory: "/tmp/bystander-project",
                panels: [
                    Self.terminalPanelSnapshot(
                        id: strayPanelId,
                        directory: "/tmp/bystander-project",
                        binding: Self.binding(sessionId: sessionId, cwd: "/tmp/owner-project", updatedAt: 500)
                    ),
                ]
            ),
        ]

        let pruned = TabManager.deduplicatingAgentSessionClaims(workspaces, restorableAgentIndex: .empty)

        #expect(pruned[0].panels[0].terminal?.resumeBinding?.checkpointId == sessionId)
        #expect(
            pruned[1].panels[0].terminal?.resumeBinding == nil,
            "A binding whose cwd is a different project than its pane must not be persisted."
        )
        #expect(pruned[1].panels[0].terminal?.wasAgentRunning == false)
    }

    // MARK: - Restore-side duplicate suppression

    @MainActor
    @Test func sessionRestoreResumesADuplicatedSessionOnlyOnce() throws {
        let sessionId = "99999999-7777-7777-7777-777777777777"
        let firstPanelId = try #require(UUID(uuidString: "55555555-5555-5555-5555-555555555555"))
        let secondPanelId = try #require(UUID(uuidString: "66666666-6666-6666-6666-666666666666"))
        let binding = Self.binding(sessionId: sessionId, cwd: "/tmp/dup-project", updatedAt: 42)

        let snapshot = Self.workspaceSnapshot(
            currentDirectory: "/tmp/dup-project",
            panels: [
                Self.terminalPanelSnapshot(id: firstPanelId, directory: "/tmp/dup-project", binding: binding),
                Self.terminalPanelSnapshot(id: secondPanelId, directory: "/tmp/dup-project", binding: binding),
            ]
        )

        let restored = Workspace()
        let restoredPanelIds = restored.restoreSessionSnapshot(snapshot)

        let restoredBindings = restoredPanelIds.values.compactMap {
            restored.surfaceResumeBinding(panelId: $0)
        }
        #expect(restoredPanelIds.count == 2, "Both panes must still be restored, as plain shells if needed.")
        #expect(
            restoredBindings.count == 1,
            "Two panes resuming one session id start two clients on one conversation, and the session-keyed hook store can name only one of them."
        )
    }

    // MARK: - Cross-project binding stripping

    // A lone binding pointing at another project used to pass straight through: the
    // dedupe pass only consults directory affinity to pick between panes claiming the
    // SAME session id, and there is no competitor here. Restore then read it back
    // verbatim and the pane ran `cd '<other project>' && claude --resume <their
    // session>`; because the pane saved the same binding again at quit, the poison
    // outlived every restart. Caught driving the tagged dev build against a session file
    // seeded with exactly this shape.
    @Test func snapshotStripsABindingRootedInAnotherWorkspacesProject() throws {
        let stripped = TabManager.strippingCrossProjectResumeBindings([
            Self.workspaceSnapshot(
                currentDirectory: "/tmp/alpha-project",
                panels: [
                    Self.terminalPanelSnapshot(
                        id: try #require(UUID(uuidString: "77777777-8888-8888-8888-888888888888")),
                        directory: "/tmp/alpha-project",
                        binding: Self.binding(
                            sessionId: "cross-project-session",
                            cwd: "/tmp/gamma-project",
                            updatedAt: 2000
                        )
                    ),
                ]
            ),
            Self.workspaceSnapshot(currentDirectory: "/tmp/gamma-project", panels: []),
        ])

        #expect(
            stripped[0].panels[0].terminal?.resumeBinding == nil,
            "alpha's pane may not carry gamma's resume command"
        )
        #expect(stripped[0].panels[0].terminal?.agent == nil)
        #expect(stripped[0].panels[0].terminal?.wasAgentRunning == false)
    }

    // The signal is "this cwd is another workspace in this same file", not "this cwd
    // differs from the pane's directory". A binding's cwd routinely differs from its
    // pane's last tracked directory -- a stale report, a scratch dir, an agent launched
    // from elsewhere -- and `testRestoreRunsSurfaceResumeBindingFromBindingCwd` pins that
    // such a pane still resumes from the binding's own cwd.
    @Test func snapshotKeepsABindingWhoseCwdIsNoOtherWorkspacesProject() throws {
        let stripped = TabManager.strippingCrossProjectResumeBindings([
            Self.workspaceSnapshot(
                currentDirectory: "/tmp/alpha-project",
                panels: [
                    Self.terminalPanelSnapshot(
                        id: try #require(UUID(uuidString: "88888888-9999-9999-9999-999999999999")),
                        directory: "/tmp/alpha-project",
                        binding: Self.binding(
                            sessionId: "scratch-session",
                            cwd: "/tmp/some-scratch-checkout",
                            updatedAt: 2000
                        )
                    ),
                ]
            ),
            Self.workspaceSnapshot(currentDirectory: "/tmp/gamma-project", panels: []),
        ])

        #expect(
            stripped[0].panels[0].terminal?.resumeBinding?.checkpointId == "scratch-session",
            "a cwd that belongs to no other workspace is not evidence of misattribution"
        )
    }

    // Containment both ways: an agent working inside a subdirectory of its own project is
    // the normal case and must survive.
    @Test func snapshotKeepsABindingRootedInASubdirectoryOfItsOwnProject() throws {
        let stripped = TabManager.strippingCrossProjectResumeBindings([
            Self.workspaceSnapshot(
                currentDirectory: "/tmp/alpha-project",
                panels: [
                    Self.terminalPanelSnapshot(
                        id: try #require(UUID(uuidString: "99999999-AAAA-AAAA-AAAA-AAAAAAAAAAAA")),
                        directory: "/tmp/alpha-project",
                        binding: Self.binding(
                            sessionId: "nested-session",
                            cwd: "/tmp/alpha-project/packages/core",
                            updatedAt: 2000
                        )
                    ),
                ]
            ),
            Self.workspaceSnapshot(currentDirectory: "/tmp/gamma-project", panels: []),
        ])

        #expect(
            stripped[0].panels[0].terminal?.resumeBinding?.checkpointId == "nested-session",
            "a nested working directory is the same project, not a different one"
        )
    }

    // MARK: - Fixtures

    private static func binding(
        sessionId: String,
        cwd: String,
        updatedAt: TimeInterval
    ) -> SurfaceResumeBindingSnapshot {
        SurfaceResumeBindingSnapshot(
            name: "Claude",
            kind: "claude",
            command: "{ cd -- '\(cwd)' 2>/dev/null || [ ! -d '\(cwd)' ]; } && 'claude' '--resume' '\(sessionId)'",
            cwd: cwd,
            checkpointId: sessionId,
            source: "agent-hook",
            autoResume: true,
            updatedAt: updatedAt
        )
    }

    private static func terminalPanelSnapshot(
        id: UUID,
        directory: String,
        binding: SurfaceResumeBindingSnapshot
    ) -> SessionPanelSnapshot {
        SessionPanelSnapshot(
            id: id,
            type: .terminal,
            title: "Terminal",
            customTitle: nil,
            directory: directory,
            isPinned: false,
            isManuallyUnread: false,
            gitBranch: nil,
            listeningPorts: [],
            ttyName: nil,
            terminal: SessionTerminalPanelSnapshot(
                workingDirectory: directory,
                resumeBinding: binding,
                wasAgentRunning: true
            ),
            browser: nil,
            markdown: nil,
            filePreview: nil,
            rightSidebarTool: nil,
            project: nil
        )
    }

    private static func workspaceSnapshot(
        currentDirectory: String,
        panels: [SessionPanelSnapshot]
    ) -> SessionWorkspaceSnapshot {
        SessionWorkspaceSnapshot(
            workspaceId: UUID(),
            processTitle: "Tests",
            customTitle: nil,
            customDescription: nil,
            customColor: nil,
            isPinned: false,
            terminalScrollBarHidden: nil,
            currentDirectory: currentDirectory,
            focusedPanelId: panels.first?.id,
            layout: .pane(SessionPaneLayoutSnapshot(
                panelIds: panels.map(\.id),
                selectedPanelId: panels.first?.id
            )),
            panels: panels,
            statusEntries: [],
            logEntries: [],
            progress: nil,
            gitBranch: nil,
            remote: nil
        )
    }

    /// A throwaway `$HOME` holding a codex hook store, so `load()` reads only fixture data.
    /// Deliberately touches no process-wide state: the hook store is found through the
    /// `homeDirectory:` argument, never `CMUX_AGENT_HOOK_STATE_DIR`. Suites run
    /// concurrently, and a test that setenv's that variable redirects every other suite's
    /// hook store lookup for as long as it runs.
    private struct HookStoreFixture {
        let root: URL

        init(prefix: String) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(prefix)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        func tearDown() {
            try? FileManager.default.removeItem(at: root)
        }

        func makeProjectDirectory(named name: String) throws -> String {
            let path = root.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
            return path.path
        }

        func record(
            sessionId: String,
            workspaceId: UUID,
            panelId: UUID,
            cwd: String,
            updatedAt: TimeInterval
        ) -> [String: Any] {
            [
                "sessionId": sessionId,
                "workspaceId": workspaceId.uuidString,
                "surfaceId": panelId.uuidString,
                "cwd": cwd,
                "isRestorable": true,
                "updatedAt": updatedAt,
                "launchCommand": [
                    "launcher": "codex",
                    "executablePath": "/usr/local/bin/codex",
                    "arguments": ["/usr/local/bin/codex"],
                    "workingDirectory": cwd,
                    "capturedAt": updatedAt,
                    "source": "test",
                ],
            ]
        }

        func writeCodexHookStore(sessions: [String: [String: Any]]) throws {
            let stateDir = root.appendingPathComponent(".cmuxterm", isDirectory: true)
            try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
            let data = try JSONSerialization.data(
                withJSONObject: ["version": 1, "sessions": sessions],
                options: [.prettyPrinted, .sortedKeys]
            )
            try data.write(
                to: stateDir.appendingPathComponent("codex-hook-sessions.json", isDirectory: false),
                options: .atomic
            )
        }

        func loadIndex(
            processArgumentsProvider: @escaping (Int) -> CmuxTopProcessArguments? = { _ in nil }
        ) -> RestorableAgentSessionIndex {
            RestorableAgentSessionIndex.load(
                homeDirectory: root.path,
                fileManager: .default,
                registry: CmuxVaultAgentRegistry(registrations: []),
                detectedSnapshots: [:],
                processArgumentsProvider: processArgumentsProvider,
                processIdentityProvider: { _ in nil },
                environment: [:]
            )
        }
    }
}
