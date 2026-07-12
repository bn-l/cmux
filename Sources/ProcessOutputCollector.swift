import CmuxFoundation
import Foundation

/// Drains a child process's stdout/stderr pipes off the main thread, keeps a
/// bounded tail of each stream, and returns their combined text on `finish()`.
///
/// This lived in the (now-removed) Cloud VM launcher; it is a generic
/// process-output helper used by the SSH-URL handler and the AppDelegate
/// external-process paths, so it now stands on its own.
final class ProcessOutputCollector: @unchecked Sendable {
    private enum Stream {
        case stdout
        case stderr
    }

    private let stdoutHandle: FileHandle
    private let stderrHandle: FileHandle
    private let lock = NSLock()
    private let byteLimit = 32 * 1024
    private var stdout = Data()
    private var stderr = Data()
    private var isFinished = false

    init(stdout: Pipe, stderr: Pipe) {
        stdoutHandle = stdout.fileHandleForReading
        stderrHandle = stderr.fileHandleForReading
    }

    func start() {
        stdoutHandle.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.append(data, to: .stdout)
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
        stderrHandle.readabilityHandler = { [weak self] handle in
            switch handle.readAvailableDataOrEndOfFile() {
            case .data(let data):
                self?.append(data, to: .stderr)
            case .wouldBlock:
                return
            case .endOfFile:
                handle.readabilityHandler = nil
            }
        }
    }

    @discardableResult
    func finish() -> String {
        lock.lock()
        guard !isFinished else {
            let output = formattedOutputLocked()
            lock.unlock()
            return output
        }
        isFinished = true
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        append(stdoutHandle.readDataToEndOfFileOrEmpty(), to: .stdout)
        append(stderrHandle.readDataToEndOfFileOrEmpty(), to: .stderr)
        try? stdoutHandle.close()
        try? stderrHandle.close()

        lock.lock()
        let output = formattedOutputLocked()
        lock.unlock()
        return output
    }

    func cancel() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        lock.unlock()

        stdoutHandle.readabilityHandler = nil
        stderrHandle.readabilityHandler = nil
        try? stdoutHandle.close()
        try? stderrHandle.close()
    }

    private func append(_ data: Data, to stream: Stream) {
        guard !data.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }

        switch stream {
        case .stdout:
            appendBounded(data, to: &stdout)
        case .stderr:
            appendBounded(data, to: &stderr)
        }
    }

    private func appendBounded(_ data: Data, to buffer: inout Data) {
        guard data.count < byteLimit else {
            buffer = Data(data.suffix(byteLimit))
            return
        }

        let overflow = buffer.count + data.count - byteLimit
        if overflow > 0 {
            buffer.removeSubrange(0..<overflow)
        }
        buffer.append(data)
    }

    private func formattedOutputLocked() -> String {
        let output = String(data: stdout, encoding: .utf8) ?? ""
        let error = String(data: stderr, encoding: .utf8) ?? ""
        return [output, error]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }
}
