import Foundation

/// Shells `cmux completion` can print a script for.
enum CMUXCompletionShell: String, CaseIterable {
    case zsh
    case bash
    case fish
}

/// Completion candidates for `cmux __complete`, computed from the CLI's own
/// command list and per-command usage text, so completion cannot drift from
/// what `cmux <command> --help` documents.
enum CMUXCompletion {
    /// Global options that come before the command. Value-taking ones consume
    /// the next word.
    static let valueTakingGlobalOptions: Set<String> = ["--socket", "--password", "--window", "--id-format"]
    static let globalOptions = ["--socket", "--password", "--window", "--id-format", "--json", "--help", "--version"]

    /// Value-taking flags whose values are live handles listed by the app.
    enum DynamicValue: String, CaseIterable {
        case workspace = "workspace.list"
        case surface = "surface.list"
        case window = "window.list"

        init?(flag: String) {
            switch flag {
            case "--workspace": self = .workspace
            case "--surface", "--panel": self = .surface
            case "--window": self = .window
            default: return nil
            }
        }

        var payloadKey: String {
            switch self {
            case .workspace: "workspaces"
            case .surface: "surfaces"
            case .window: "windows"
            }
        }
    }

    /// Candidates for the last element of `words` (the word being completed,
    /// possibly empty). `words` excludes the leading `cmux`.
    static func candidates(
        words: [String],
        commands: Set<String>,
        usage: (String) -> String?,
        dynamicValues: (DynamicValue) -> [String]
    ) -> [String] {
        guard let current = words.last else { return [] }
        let preceding = words.dropLast()

        var index = preceding.startIndex
        var previous: String?
        while index < preceding.endIndex, preceding[index].hasPrefix("-") {
            let option = preceding[index]
            previous = option
            index = preceding.index(after: index)
            if valueTakingGlobalOptions.contains(option), index < preceding.endIndex {
                previous = preceding[index]
                index = preceding.index(after: index)
            }
        }

        guard index < preceding.endIndex else {
            // Completing the command word itself, or a global option value.
            if let previous, valueTakingGlobalOptions.contains(previous) {
                return previous == "--window" ? matching(dynamicValues(.window), current) : []
            }
            let pool = current.hasPrefix("-")
                ? globalOptions
                : commands.filter { !$0.hasPrefix("_") }.sorted()
            return matching(pool, current)
        }

        let command = preceding[index]
        let arguments = preceding[preceding.index(after: index)...]
        let text = usage(command) ?? ""
        if let flag = arguments.last, flag.hasPrefix("--") {
            if let dynamic = DynamicValue(flag: flag) {
                return matching(dynamicValues(dynamic), current)
            }
            if flagTakesValue(flag, usage: text) {
                return []
            }
        }
        if current.hasPrefix("-") {
            return matching(flags(fromUsage: text) + ["--help"], current)
        }
        if arguments.allSatisfy({ $0.hasPrefix("-") }) {
            return matching(subcommands(fromUsage: text, command: command), current)
        }
        return []
    }

    /// `--flags` mentioned anywhere in the usage text, in order, without duplicates.
    static func flags(fromUsage usage: String) -> [String] {
        let pattern = #/(?:^|[^A-Za-z0-9-])(--[a-z][a-z0-9-]*)/#
        var seen: Set<String> = []
        return usage.matches(of: pattern).map { String($0.output.1) }.filter { seen.insert($0).inserted }
    }

    /// True when the usage text shows the flag followed by a `<value>`.
    static func flagTakesValue(_ flag: String, usage: String) -> Bool {
        usage.contains("\(flag) <") || usage.contains("\(flag)=<")
    }

    /// Subcommand names from `cmux <command> <a|b|c>` usage lines and from
    /// two-space-indented entries under a `Subcommands:` heading.
    static func subcommands(fromUsage usage: String, command: String) -> [String] {
        var names: [String] = []
        let lines = usage.split(separator: "\n", omittingEmptySubsequences: false)
        let alternation = #/cmux [a-z0-9-]+ <([a-z0-9-]+(?:\|[a-z0-9-]+)+)>/#
        for line in lines where line.contains("cmux \(command) <") {
            if let match = line.firstMatch(of: alternation) {
                names += match.output.1.split(separator: "|").map(String.init)
            }
        }
        let entry = #/^  ([a-z][a-z0-9-]*(?:\|[a-z][a-z0-9-]*)*)(?:\s|$)/#
        var inSection = false
        for line in lines {
            if line.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("subcommands:") {
                inSection = true
                continue
            }
            guard inSection else { continue }
            if !line.isEmpty, !line.hasPrefix(" ") {
                inSection = false
                continue
            }
            if let match = line.firstMatch(of: entry) {
                names += match.output.1.split(separator: "|").map(String.init)
            }
        }
        var seen: Set<String> = []
        return names.filter { seen.insert($0).inserted }
    }

    private static func matching(_ pool: [String], _ prefix: String) -> [String] {
        pool.filter { $0.hasPrefix(prefix) }
    }

    static func script(for shell: CMUXCompletionShell) -> String {
        switch shell {
        case .zsh:
            return #"""
            #compdef cmux
            _cmux() {
              local -a candidates
              candidates=("${(@f)$(command cmux __complete "${(@)words[2,CURRENT]}" 2>/dev/null)}")
              if [[ -n "${candidates[1]}" ]]; then
                compadd -- "${candidates[@]}"
              else
                _files
              fi
            }
            compdef _cmux cmux
            """#
        case .bash:
            return #"""
            _cmux() {
              local line="${COMP_LINE:0:COMP_POINT}" candidate
              local -a words
              IFS=$' \t\n' read -r -a words <<< "$line"
              [[ "$line" == *[[:space:]] ]] && words+=("")
              local cur="${words[${#words[@]}-1]}"
              COMPREPLY=()
              # No `local IFS`: macOS /bin/bash 3.2 leaks it into the next call.
              while IFS= read -r candidate; do
                COMPREPLY+=("$candidate")
              done < <(command cmux __complete "${words[@]:1}" 2>/dev/null)
              if [[ "$cur" == *:* && "$COMP_WORDBREAKS" == *:* ]]; then
                local colon_prefix="${cur%"${cur##*:}"}"
                COMPREPLY=("${COMPREPLY[@]#"$colon_prefix"}")
              fi
            }
            complete -o default -F _cmux cmux
            """#
        case .fish:
            return #"""
            function __cmux_complete
                set -l tokens (commandline -opc)
                set -e tokens[1]
                set -l candidates (command cmux __complete $tokens (commandline -ct) 2>/dev/null)
                if test (count $candidates) -gt 0
                    printf '%s\n' $candidates
                else
                    __fish_complete_path (commandline -ct)
                end
            end
            complete -c cmux -f -a '(__cmux_complete)'
            """#
        }
    }
}

extension CMUXCLI {
    /// `cmux completion <zsh|bash|fish>`: prints the shell script.
    func runCompletionCommand(commandArgs: [String]) throws {
        guard commandArgs.count == 1, let shell = CMUXCompletionShell(rawValue: commandArgs[0]) else {
            // Matches the English-only usage text of every other subcommand.
            throw CLIError(message: subcommandUsage("completion") ?? "", exitCode: 2)
        }
        print(CMUXCompletion.script(for: shell))
    }

    /// `cmux __complete <words...>`: prints one candidate per line for the last
    /// word. Never fails: a broken socket or unknown command prints nothing, so
    /// the shell falls back to file completion.
    func runCompleteCommand(words: [String], processEnv: [String: String]) {
        let candidates = CMUXCompletion.candidates(
            words: words,
            commands: Self.topLevelCommandNames,
            usage: { subcommandUsage($0) },
            dynamicValues: { completionHandles($0, words: words, processEnv: processEnv) }
        )
        if !candidates.isEmpty {
            print(candidates.joined(separator: "\n"))
        }
    }

    /// Lists live handles (e.g. `workspace:2`) from the running app, bounded so a
    /// stalled socket cannot hang the shell.
    private func completionHandles(
        _ kind: CMUXCompletion.DynamicValue,
        words: [String],
        processEnv: [String: String]
    ) -> [String] {
        let explicitSocket = words.firstIndex(of: "--socket").flatMap { words.indices.contains($0 + 1) ? words[$0 + 1] : nil }
        let password = words.firstIndex(of: "--password").flatMap { words.indices.contains($0 + 1) ? words[$0 + 1] : nil }
        let bundleIdentifier = CLISocketPathResolver.currentAppBundleIdentifier()
        let environmentSocket = CLISocketEnvironment.socketPathForDiagnostics(in: processEnv)
        let socketPath = CLISocketPathResolver.resolve(
            requestedPath: explicitSocket ?? environmentSocket ?? CLISocketPathResolver.defaultSocketPath(
                bundleIdentifier: bundleIdentifier,
                environment: processEnv
            ),
            source: explicitSocket != nil ? .explicitFlag : (environmentSocket != nil ? .environment : .implicitDefault),
            environment: processEnv,
            bundleIdentifier: bundleIdentifier
        )
        let timeout: TimeInterval = 0.5
        let client = SocketClient(path: socketPath)
        defer { client.close() }
        do {
            try client.connectWithoutRetry(responseTimeout: timeout)
            try authenticateClientIfNeeded(
                client,
                explicitPassword: password,
                socketPath: socketPath,
                responseTimeout: timeout
            )
            let payload = try client.sendV2(method: kind.rawValue, responseTimeout: timeout)
            let items = payload[kind.payloadKey] as? [[String: Any]] ?? []
            return items.compactMap { $0["ref"] as? String }
        } catch {
            return []
        }
    }
}
