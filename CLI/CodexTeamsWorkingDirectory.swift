import Foundation

/// The working directory `cmux codex-teams` passes through to Codex
/// (`-C`, `--cd`, `--cwd`), resolved against the launch directory.
enum CodexTeamsWorkingDirectory {
    static func resolved(
        commandArgs: [String],
        baseDirectory: String
    ) -> String? {
        let valueOptions: Set<String> = ["-C", "--cd", "--cwd"]
        let optionPrefixes = valueOptions.map { "\($0)=" }
        var index = 0
        var requested: String?
        while index < commandArgs.count {
            let arg = commandArgs[index]
            if arg == "--" { break }
            if valueOptions.contains(arg), index + 1 < commandArgs.count {
                requested = commandArgs[index + 1]
                index += 2
                continue
            }
            if let prefix = optionPrefixes.first(where: { arg.hasPrefix($0) }) {
                requested = String(arg.dropFirst(prefix.count))
            }
            index += 1
        }
        guard let requested = requested?.trimmingCharacters(in: .whitespacesAndNewlines),
              !requested.isEmpty else {
            return nil
        }
        let expanded = (requested as NSString).expandingTildeInPath
        if expanded.hasPrefix("/") {
            return URL(fileURLWithPath: expanded).standardizedFileURL.path
        }
        return URL(
            fileURLWithPath: expanded,
            relativeTo: URL(fileURLWithPath: baseDirectory, isDirectory: true)
        ).standardizedFileURL.path
    }

    static func validate(
        commandArgs: [String],
        baseDirectory: String
    ) throws {
        guard let cwd = resolved(commandArgs: commandArgs, baseDirectory: baseDirectory) else {
            return
        }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw NSError(
                domain: "CodexTeamsWorkingDirectory",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "cmux codex-teams cwd does not exist: \(cwd)"]
            )
        }
    }
}
