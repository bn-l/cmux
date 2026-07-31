import Foundation

/// Builds hermetic child-process environments for tests that spawn shells or
/// agent binaries.
///
/// # Why this exists
///
/// A test that does `var env = ProcessInfo.processInfo.environment` inherits the
/// real environment of whoever launched the test runner. When that is a cmux
/// terminal (the normal case: `reload.sh`, or Xcode opened from a cmux tab), the
/// inherited environment carries `CMUX_CODEX_WRAPPER_SHIM` /
/// `CMUX_CLAUDE_WRAPPER_SHIM`.
///
/// The resume command cmux generates (`AgentResumeArgv.swift`) does **not** do a
/// plain `PATH` lookup — it prefers the shim:
///
/// ```sh
/// "$([ -x "${CMUX_CODEX_WRAPPER_SHIM:-}" ] && printf '%s' "$CMUX_CODEX_WRAPPER_SHIM" || printf codex)"
/// ```
///
/// So an inherited real shim wins over whatever fake stub the test installed on
/// `PATH`, and the user's real, authenticated agent is launched — historically
/// `codex resume <fake-session> --yolo`. That process is orphaned to launchd when
/// its parent shell exits and spins its event loop forever.
///
/// # Why prepending a fake bin to PATH is not enough
///
/// Tests commonly spawn `zsh -lc` / `zsh -lic`. A **login** shell runs
/// `/etc/zprofile`, which runs `path_helper`, which rebuilds `PATH` from
/// `/etc/paths` + `/etc/paths.d` and appends the inherited entries *after* them.
/// On any machine with Homebrew, `/etc/paths.d/homebrew` contributes
/// `/opt/homebrew/bin`, so a prepended fake bin ends up behind the real binary:
///
/// ```
/// env -i HOME=<empty> PATH=<fakebin>:/usr/bin:/bin zsh -lc 'command -v codex'
/// → /opt/homebrew/bin/codex
/// ```
///
/// That is a second, independent route to the real binary. Pointing the shim
/// variable at the fake stub is the only approach that survives it, because it
/// removes `PATH` from the decision entirely.
///
/// # Usage
///
/// ```swift
/// var environment = AgentSpawnIsolation.childEnvironment(
///     home: root,
///     prependingPath: [bin.path],
///     fakeAgents: [.codex: fakeCodexURL]
/// )
/// environment["CMUX_FAKE_CODEX_OUTPUT"] = outputURL.path
/// process.environment = environment
/// ```
///
/// `Resources/bin/cmux-{codex,claude}-wrapper` also refuse to exec under XCTest,
/// so a test that forgets this helper fails loudly instead of silently launching
/// a real agent. Treat that guard as a safety net, not a licence to skip this.
enum AgentSpawnIsolation {
    /// An agent whose cmux wrapper shim can be redirected at a test stub.
    enum Agent: String, CaseIterable {
        case codex
        case claude

        var shimKey: String { "CMUX_\(rawValue.uppercased())_WRAPPER_SHIM" }
        var shimRootKey: String { "CMUX_\(rawValue.uppercased())_WRAPPER_SHIM_ROOT" }
        var customPathKey: String { "CMUX_CUSTOM_\(rawValue.uppercased())_PATH" }
    }

    /// Inherited variables that let a spawned child reach the user's real agent
    /// binaries, real agent config, or live cmux instance. All are removed
    /// unless the caller re-supplies them explicitly.
    static let unsafeInheritedKeys: [String] = {
        var keys = [
            "CMUX_SOCKET_PATH",
            "CMUX_SOCKET",
            "CMUX_SOCKET_PASSWORD",
            "CMUX_BUNDLED_CLI_PATH",
            "CODEX_HOME",
            "CLAUDE_CONFIG_DIR",
            // zsh reads .zprofile/.zshrc from ZDOTDIR when it is set, which would
            // bypass the profile writeLoginShellPathProfile drops in `home`.
            // cmux sets ZDOTDIR for shell integration, so it is normally present.
            "ZDOTDIR",
            "CMUX_ZSH_ZDOTDIR",
            "CMUX_SHELL_INTEGRATION_DIR",
        ]
        for agent in Agent.allCases {
            keys.append(agent.shimKey)
            keys.append(agent.shimRootKey)
            keys.append(agent.customPathKey)
        }
        return keys
    }()

    /// Builds a scrubbed environment for a spawned child process.
    ///
    /// - Parameters:
    ///   - home: Sandbox `HOME`. Required, not optional: a login shell sources
    ///     `HOME`'s rc files, and the user's real rc files put the real agent
    ///     binaries back on `PATH`.
    ///   - prependingPath: Entries placed at the front of `PATH`. Also written
    ///     into a `.zprofile` under `home` so they survive a login shell (see
    ///     `writeLoginShellPathProfile`).
    ///   - fakeAgents: Stub binaries to bind each agent's wrapper shim to. Only
    ///     affects commands that use the shim selector; commands naming a bare
    ///     binary (`codex resume ...`) still resolve through `PATH`, which is
    ///     why both mechanisms are applied.
    ///   - base: Environment to scrub. Defaults to the current process.
    static func childEnvironment(
        home: URL,
        prependingPath extraPathEntries: [String] = [],
        fakeAgents: [Agent: URL] = [:],
        base: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        if !extraPathEntries.isEmpty {
            try? writeLoginShellPathProfile(home: home, prepending: extraPathEntries)
        }
        var environment = base
        for key in unsafeInheritedKeys {
            environment.removeValue(forKey: key)
        }

        environment["HOME"] = home.path

        let inheritedPath = base["PATH"] ?? "/usr/bin:/bin"
        // Drop cmux shim directories: they contain `codex`/`claude` shims that
        // re-exec the real wrapper regardless of what the test installed.
        let survivingEntries = inheritedPath
            .split(separator: ":", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !$0.contains("cmux-cli-shims") }
        environment["PATH"] = (extraPathEntries + survivingEntries).joined(separator: ":")

        for (agent, url) in fakeAgents {
            environment[agent.shimKey] = url.path
            environment[agent.shimRootKey] = url.deletingLastPathComponent().path
        }

        return environment
    }

    /// Writes a `.zprofile` (and `.zshrc`) under `home` that re-prepends
    /// `entries` to `PATH`.
    ///
    /// A login shell sources `/etc/zprofile`, which runs `path_helper`, which
    /// rebuilds `PATH` from `/etc/paths` + `/etc/paths.d` and appends the
    /// inherited entries *behind* them. On a machine with Homebrew that puts
    /// `/opt/homebrew/bin` ahead of a test's fake bin, so a command naming a bare
    /// `codex` resolves to the real binary no matter what the test set in the
    /// child environment.
    ///
    /// `~/.zprofile` is sourced immediately after `/etc/zprofile`, so it is the
    /// first point at which a test can win that fight. `.zshrc` covers `-lic`
    /// (interactive) spawns, which source it later still.
    static func writeLoginShellPathProfile(home: URL, prepending entries: [String]) throws {
        guard !entries.isEmpty else { return }
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let prefix = entries.joined(separator: ":")
        let body = """
        # Written by AgentSpawnIsolation: re-prepend the test's bin after
        # /etc/zprofile's path_helper has reshuffled PATH.
        export PATH="\(prefix):$PATH"

        """
        for name in [".zprofile", ".zshrc"] {
            try body.write(
                to: home.appendingPathComponent(name, isDirectory: false),
                atomically: true,
                encoding: .utf8
            )
        }
    }

    /// Runs `process` to completion, terminating it if it outlives `timeout`.
    ///
    /// A plain `waitUntilExit()` on a leaked agent TUI never returns, which turns
    /// one bad spawn into a hung suite. This bounds that.
    ///
    /// - Returns: The process's termination status.
    @discardableResult
    static func runToCompletion(
        _ process: Process,
        timeout: TimeInterval = 60
    ) throws -> Int32 {
        try process.run()
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            let killDeadline = Date().addingTimeInterval(2)
            while process.isRunning, Date() < killDeadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
            }
            process.waitUntilExit()
            return -1
        }
        process.waitUntilExit()
        return process.terminationStatus
    }
}
