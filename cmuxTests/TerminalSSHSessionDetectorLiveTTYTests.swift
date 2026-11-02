import Darwin
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Image paste resolves its upload target on the main thread through
/// `TerminalSSHSessionDetector`. These tests run a real `ssh` as the
/// foreground job of a real pty and check the kernel-read process table and
/// the detected session against `/bin/ps`, the tool the detector used before.
///
/// The `ssh` never touches the network: `ProxyCommand=/bin/sleep 20` stands in
/// for the transport, so it waits for a server banner that never comes and
/// exits on its own after 20 s if a test dies before cleanup.
@Suite(.serialized) struct TerminalSSHSessionDetectorLiveTTYTests {
    private struct LiveSSH {
        let script: Process
        let sshPID: Int32
        let ttyName: String
        let home: URL

        func stop() {
            kill(sshPID, SIGTERM)
            script.terminate()
            script.waitUntilExit()
            try? FileManager.default.removeItem(at: home)
        }
    }

    private struct PSRow: Equatable, Comparable {
        let pid: Int32
        let pgid: Int32
        let tpgid: Int32
        let tty: String
        let executableName: String

        static func < (lhs: PSRow, rhs: PSRow) -> Bool { lhs.pid < rhs.pid }
    }

    @Test func kernelProcessTableMatchesPsForALiveTTY() throws {
        // Arrange
        let live = try startForegroundSSH()
        defer { live.stop() }

        // Act
        let snapshot = TerminalSSHSessionDetector.processSnapshots(forTTY: live.ttyName)
        let psRows = try psRows(forTTY: live.ttyName)

        // Assert
        let snapshotRows = snapshot.map {
            PSRow(pid: $0.pid, pgid: $0.pgid, tpgid: $0.tpgid, tty: $0.tty, executableName: $0.executableName)
        }.sorted()
        #expect(snapshotRows == psRows, "The sysctl table must list the same processes `ps -t` lists")
        #expect(snapshotRows.contains { $0.pid == live.sshPID && $0.executableName == "ssh" && $0.pgid == $0.tpgid },
                "The live ssh must be the tty's foreground job")
        #expect(snapshotRows.contains { $0.executableName == "sleep" && $0.pgid == live.sshPID },
                "The ProxyCommand child shares ssh's process group")
    }

    @Test func detectFindsTheForegroundSSHSessionOnALiveTTY() throws {
        // Arrange
        let live = try startForegroundSSH()
        defer { live.stop() }

        // Act
        let session = TerminalSSHSessionDetector.detect(forTTY: "/dev/\(live.ttyName)")

        // Assert
        let detected = try #require(session, "No session detected on \(live.ttyName)")
        #expect(detected.destination == "user@example.com")
        #expect(detected.port == 2222)
        #expect(detected.configFile == "/dev/null")
    }

    /// Image paste calls this on the main thread. Launching any process costs
    /// at least ~5 ms on an M-series Mac (measured: `ps` 5.2 ms, `true` 6 ms,
    /// fastest of 40); the kernel read takes microseconds. The fastest of 20
    /// reads stays under 1 ms even on a loaded machine unless a subprocess
    /// comes back.
    @Test func processTableReadDoesNotLaunchAProcess() throws {
        // Arrange
        let live = try startForegroundSSH()
        defer { live.stop() }
        let clock = ContinuousClock()

        // Act
        let fastest = (0..<20).map { _ in
            clock.measure { _ = TerminalSSHSessionDetector.processSnapshots(forTTY: live.ttyName) }
        }.min()!

        // Assert
        #expect(fastest < .milliseconds(1), "Fastest read took \(fastest); a subprocess costs ≥ 5 ms")
    }

    @Test func unknownTTYHasNoProcessesAndNoSession() {
        #expect(TerminalSSHSessionDetector.processSnapshots(forTTY: "ttys999999").isEmpty)
        #expect(TerminalSSHSessionDetector.detect(forTTY: "ttys999999") == nil)
    }

    // MARK: - Helpers

    private func startForegroundSSH() throws -> LiveSSH {
        let home = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ssh-detector-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)

        let script = Process()
        script.executableURL = URL(fileURLWithPath: "/usr/bin/script")
        script.arguments = [
            "-q", "/dev/null",
            "/usr/bin/ssh", "-F", "/dev/null", "-o", "ProxyCommand=/bin/sleep 20",
            "-p", "2222", "user@example.com",
        ]
        // Never inherit the test runner's environment (see CLAUDE.md pitfalls).
        script.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
        script.standardInput = FileHandle.nullDevice
        script.standardOutput = FileHandle.nullDevice
        script.standardError = FileHandle.nullDevice
        try script.run()

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let sshPID = try childPIDs(of: script.processIdentifier).first,
               let ttyName = try ttyName(of: sshPID),
               try psRows(forTTY: ttyName).contains(where: { $0.executableName == "sleep" }) {
                return LiveSSH(script: script, sshPID: sshPID, ttyName: ttyName, home: home)
            }
            usleep(20_000)
        }
        script.terminate()
        script.waitUntilExit()
        try? FileManager.default.removeItem(at: home)
        throw LiveSSHStartFailure()
    }

    private struct LiveSSHStartFailure: Error, CustomStringConvertible {
        var description: String { "ssh under /usr/bin/script did not reach its ProxyCommand on a pty within 5 s" }
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    private func childPIDs(of pid: Int32) throws -> [Int32] {
        try run("/usr/bin/pgrep", ["-P", String(pid)])
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
    }

    private func ttyName(of pid: Int32) throws -> String? {
        let name = try run("/bin/ps", ["-o", "tty=", "-p", String(pid)])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.hasPrefix("ttys") ? name : nil
    }

    private func psRows(forTTY ttyName: String) throws -> [PSRow] {
        try run("/bin/ps", ["-ww", "-t", ttyName, "-o", "pid=,pgid=,tpgid=,tty=,ucomm="])
            .split(whereSeparator: \.isNewline)
            .compactMap { line -> PSRow? in
                let parts = line.split(maxSplits: 4, whereSeparator: \.isWhitespace)
                guard parts.count == 5, let pid = Int32(parts[0]), let pgid = Int32(parts[1]),
                      let tpgid = Int32(parts[2]) else { return nil }
                return PSRow(
                    pid: pid, pgid: pgid, tpgid: tpgid, tty: String(parts[3]),
                    executableName: parts[4].trimmingCharacters(in: .whitespaces).lowercased()
                )
            }
            .sorted()
    }
}
