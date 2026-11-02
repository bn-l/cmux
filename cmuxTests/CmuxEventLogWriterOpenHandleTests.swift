import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Upstream #14829: the event log stays open across flushes, but other cmux
/// processes share `~/.cmuxterm/events.jsonl` and may rotate, delete or append
/// to it, so every flush must still land in the file now at the path, without
/// overwriting anyone else's lines.
struct CmuxEventLogWriterOpenHandleTests {
    private func makeWriter(maxBytes: UInt64 = 16 * 1024 * 1024) throws -> (CmuxEventLogWriter, URL) {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-event-log-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("events.jsonl")
        return (CmuxEventLogWriter(eventLogURL: url, maxEventLogBytes: maxBytes, maxPendingLines: 64), url)
    }

    private func flush(_ lines: [String], with writer: CmuxEventLogWriter) {
        lines.forEach(writer.enqueue)
        writer.flushForTesting()
    }

    private func contents(_ url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
    }

    @Test func consecutiveFlushesReuseOneOpenDescriptor() throws {
        let (writer, url) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        flush([#"{"seq":1}"#], with: writer)
        let first = writer.openLogFileDescriptorForTesting()
        flush([#"{"seq":2}"#], with: writer)
        flush([#"{"seq":3}"#], with: writer)

        #expect(first != nil, "The log must stay open after a flush")
        #expect(writer.openLogFileDescriptorForTesting() == first)
        #expect(try contents(url) == "{\"seq\":1}\n{\"seq\":2}\n{\"seq\":3}\n")
    }

    @Test(arguments: [false, true])
    func externalRotationOrDeletionBetweenFlushesWritesToCurrentPath(deleteInsteadOfRotate: Bool) throws {
        let (writer, url) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rotatedURL = url.appendingPathExtension("external")

        flush([#"{"seq":1}"#], with: writer)
        if deleteInsteadOfRotate {
            try FileManager.default.removeItem(at: url)
        } else {
            try FileManager.default.moveItem(at: url, to: rotatedURL)
        }
        flush([#"{"seq":2}"#], with: writer)

        #expect(try contents(url) == "{\"seq\":2}\n")
        if !deleteInsteadOfRotate {
            #expect(try contents(rotatedURL) == "{\"seq\":1}\n")
        }
    }

    @Test func externalRotationWithReplacementFileWritesToReplacement() throws {
        let (writer, url) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let rotatedURL = url.appendingPathExtension("external")

        flush([#"{"seq":1}"#], with: writer)
        try FileManager.default.moveItem(at: url, to: rotatedURL)
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        flush([#"{"seq":2}"#], with: writer)

        #expect(try contents(url) == "{\"seq\":2}\n")
        #expect(try contents(rotatedURL) == "{\"seq\":1}\n")
    }

    @Test func externalAppendBetweenFlushesIsNotOverwritten() throws {
        let (writer, url) = try makeWriter()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        flush([#"{"seq":1}"#], with: writer)
        let external = try FileHandle(forWritingTo: url)
        try external.seekToEnd()
        try external.write(contentsOf: Data("{\"external\":true}\n".utf8))
        try external.close()
        flush([#"{"seq":2}"#], with: writer)

        #expect(
            try contents(url) == "{\"seq\":1}\n{\"external\":true}\n{\"seq\":2}\n",
            "A kept-open descriptor must append, not write at its stale offset"
        )
    }

    @Test func sizeRotationStillMovesTheFullLogAside() throws {
        let (writer, url) = try makeWriter(maxBytes: 24)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        flush([#"{"seq":1}"#, #"{"seq":2}"#], with: writer)
        flush([#"{"seq":3}"#], with: writer)

        #expect(try contents(url) == "{\"seq\":3}\n")
        #expect(try contents(url.appendingPathExtension("1")) == "{\"seq\":1}\n{\"seq\":2}\n")
    }
}
