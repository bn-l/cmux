import Darwin
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Exercises the libproc lookup against real sockets owned by the test process,
/// the same kernel path the port scanner uses instead of spawning `lsof`.
@Suite("ListeningPortLookup", .serialized)
struct ListeningPortLookupTests {
    @Test("Reports a listening TCP socket and drops it once closed")
    func reportsListeningSocketUntilClosed() throws {
        let listener = try LoopbackTCPSocket(listen: true)
        let port = listener.port

        guard case .ports(let whileListening) = ListeningPortLookup.ports(pid: getpid()) else {
            Issue.record("Own process must be inspectable")
            return
        }
        #expect(whileListening.contains(port))

        listener.close()

        guard case .ports(let afterClose) = ListeningPortLookup.ports(pid: getpid()) else {
            Issue.record("Own process must be inspectable")
            return
        }
        #expect(!afterClose.contains(port))
    }

    @Test("Ignores a bound TCP socket that is not listening")
    func ignoresBoundSocketThatIsNotListening() throws {
        let bound = try LoopbackTCPSocket(listen: false)
        defer { bound.close() }

        guard case .ports(let ports) = ListeningPortLookup.ports(pid: getpid()) else {
            Issue.record("Own process must be inspectable")
            return
        }
        #expect(!ports.contains(bound.port))
    }

    @Test("Non-positive and vanished PIDs are unavailable")
    func unavailableForMissingProcesses() {
        #expect(ListeningPortLookup.ports(pid: 0) == .unavailable)
        #expect(ListeningPortLookup.ports(pid: -1) == .unavailable)
        // PID_MAX on macOS is 99_999; this PID can never exist.
        #expect(ListeningPortLookup.ports(pid: 999_999) == .unavailable)
    }

    @Test("Another user's process is denied rather than reported empty")
    func deniedForForeignProcess() throws {
        try #require(getuid() != 0, "Running as root can inspect launchd; this case needs an unprivileged user")
        #expect(ListeningPortLookup.ports(pid: 1) == .denied)
    }
}

/// A loopback IPv4 TCP socket bound to an ephemeral port.
private final class LoopbackTCPSocket {
    private var descriptor: Int32
    let port: Int

    init(listen shouldListen: Bool) throws {
        let fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP)
        guard fd >= 0 else { throw SocketError.call("socket", errno) }

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.call("bind", code)
        }
        if shouldListen, Darwin.listen(fd, 1) != 0 {
            let code = errno
            Darwin.close(fd)
            throw SocketError.call("listen", code)
        }

        var resolved = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &resolved) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &length)
            }
        }
        guard named == 0 else {
            let code = errno
            Darwin.close(fd)
            throw SocketError.call("getsockname", code)
        }
        descriptor = fd
        port = Int(UInt16(bigEndian: resolved.sin_port))
    }

    func close() {
        guard descriptor >= 0 else { return }
        Darwin.close(descriptor)
        descriptor = -1
    }

    deinit { close() }
}

private enum SocketError: Error {
    case call(String, Int32)
}
