import Foundation

enum CLISocketEnvironment {
    static func socketPath(in environment: [String: String]) throws -> String? {
        let socketPath = normalized(environment["CMUX_SOCKET_PATH"])
        let legacySocketPath = normalized(environment["CMUX_SOCKET"])
        if let socketPath, let legacySocketPath, socketPath != legacySocketPath {
            throw CLIError(message: String(
                localized: "cli.socket.error.conflictingEnvironment",
                defaultValue: "Refusing to choose socket: CMUX_SOCKET_PATH and CMUX_SOCKET differ. Use CMUX_SOCKET_PATH or unset CMUX_SOCKET."
            ))
        }
        return socketPath ?? legacySocketPath
    }

    static func socketPathForDiagnostics(in environment: [String: String]) -> String? {
        normalized(environment["CMUX_SOCKET_PATH"]) ?? normalized(environment["CMUX_SOCKET"])
    }

    private static func normalized(_ raw: String?) -> String? {
        let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Local no-op diagnostics sink. This replaced the former Sentry uploader; it is
/// retained only so the CLI hook call-graph keeps its `telemetry:` parameter
/// without a large signature refactor. Nothing leaves the process.
final class CLISocketDiagnostics {
    init(command: String, commandArgs: [String], socketPath: String, processEnv: [String: String]) {}

    func breadcrumb(_ message: String, data: [String: Any] = [:]) {}

    func captureError(stage: String, error: Error, data: [String: Any] = [:]) {}
}
