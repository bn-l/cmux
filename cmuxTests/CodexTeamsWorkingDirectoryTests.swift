import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@Suite("Codex Teams working directory")
struct CodexTeamsWorkingDirectoryTests {
    @Test func resolvesExplicitWorkingDirectoryFlags() {
        let base = "/tmp/cmux-base"

        #expect(
            CodexTeamsWorkingDirectory.resolved(
                commandArgs: ["-C", "child", "prompt"],
                baseDirectory: base
            ) == "/tmp/cmux-base/child"
        )
        #expect(
            CodexTeamsWorkingDirectory.resolved(
                commandArgs: ["--cwd=/tmp/cmux-review", "--cd", "/tmp/cmux-final"],
                baseDirectory: base
            ) == "/tmp/cmux-final"
        )
        #expect(
            CodexTeamsWorkingDirectory.resolved(
                commandArgs: ["--", "-C", "/tmp/inside-prompt"],
                baseDirectory: base
            ) == nil
        )
    }

    @Test func validatesExplicitWorkingDirectoryExists() throws {
        let existing = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-teams-cwd-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: existing, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: existing) }

        do {
            try CodexTeamsWorkingDirectory.validate(
                commandArgs: ["-C", existing.path],
                baseDirectory: "/tmp"
            )
        } catch {
            Issue.record("existing Codex Teams cwd should validate: \(error)")
        }

        #expect(throws: (any Error).self, "missing Codex Teams cwd should throw") {
            try CodexTeamsWorkingDirectory.validate(
                commandArgs: ["-C", existing.appendingPathComponent("missing").path],
                baseDirectory: "/tmp"
            )
        }
    }
}
