import XCTest
@testable import cmux_DEV

final class TerminalRemoteDaemonSessionTransportTests: XCTestCase {
    func testConnectEmitsConnectedAndPollsTerminalOutput() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                capabilities: ["terminal.stream"]
            ),
            openResult: .init(
                sessionID: "sess-1",
                attachmentID: "att-1",
                attachments: [],
                effectiveCols: 120,
                effectiveRows: 40,
                lastKnownCols: 120,
                lastKnownRows: 40,
                offset: 0
            ),
            readResults: [
                Result<TerminalRemoteDaemonTerminalReadResult, Error>.success(
                    .init(
                        sessionID: "sess-1",
                        offset: 5,
                        baseOffset: 0,
                        truncated: false,
                        eof: false,
                        data: Data("READY".utf8)
                    )
                )
            ]
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo"
        )

        let connectedExpectation = expectation(description: "connected")
        let outputExpectation = expectation(description: "output")
        transport.eventHandler = { (event: TerminalTransportEvent) in
            switch event {
            case .connected:
                connectedExpectation.fulfill()
            case .output(let data) where data == Data("READY".utf8):
                outputExpectation.fulfill()
            default:
                break
            }
        }

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 120, rows: 40))

        await fulfillment(of: [connectedExpectation, outputExpectation], timeout: 1.0)
        await transport.disconnect()

        let openedCommands = await client.openedCommands()
        XCTAssertEqual(openedCommands, ["tmux new-session -A -s demo"])
    }

    func testSendResizeAndDisconnectForwardToDaemonClient() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                capabilities: ["terminal.stream"]
            ),
            attachResult: nil,
            openResult: .init(
                sessionID: "sess-9",
                attachmentID: "att-9",
                attachments: [],
                effectiveCols: 80,
                effectiveRows: 24,
                lastKnownCols: 80,
                lastKnownRows: 24,
                offset: 0
            ),
            readResults: []
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo"
        )

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 80, rows: 24))
        try await transport.send(Data("ls\n".utf8))
        await transport.resize(TerminalGridSize.fixture(columns: 100, rows: 30))
        await transport.disconnect()

        let writes = await client.recordedWrites()
        XCTAssertEqual(writes, [Data("ls\n".utf8)])

        let resizeCalls = await client.recordedResizes()
        XCTAssertEqual(resizeCalls.count, 1)
        XCTAssertEqual(resizeCalls.first?.sessionID, "sess-9")
        XCTAssertEqual(resizeCalls.first?.attachmentID, "att-9")
        XCTAssertEqual(resizeCalls.first?.cols, 100)
        XCTAssertEqual(resizeCalls.first?.rows, 30)

        let closedSessions = await client.closedSessions()
        XCTAssertEqual(closedSessions, ["sess-9"])
    }

    func testSuspendPreservingSessionDetachesInsteadOfClosingSession() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                capabilities: ["terminal.stream"]
            ),
            attachResult: nil,
            openResult: .init(
                sessionID: "sess-park",
                attachmentID: "att-park",
                attachments: [],
                effectiveCols: 90,
                effectiveRows: 20,
                lastKnownCols: 90,
                lastKnownRows: 20,
                offset: 0
            ),
            readResults: []
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo"
        )

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 90, rows: 20))
        await transport.suspendPreservingSession()

        let detachCalls = await client.recordedDetaches()
        let closedSessions = await client.closedSessions()
        XCTAssertEqual(detachCalls.count, 1)
        XCTAssertEqual(detachCalls.first?.sessionID, "sess-park")
        XCTAssertEqual(detachCalls.first?.attachmentID, "att-park")
        XCTAssertEqual(closedSessions, [])
    }

    func testDefaultTransportFactoryUsesInjectedRemoteDaemonBuilder() {
        let expectedTransport = StubTerminalTransport()
        let factory = DefaultTerminalTransportFactory(
            remoteDaemonBuilder: { _, _, _, _ in expectedTransport }
        )
        let host = TerminalHost(
            name: "Mac Mini",
            hostname: "cmux-macmini",
            username: "cmux",
            symbolName: "desktopcomputer",
            palette: .mint,
            transportPreference: .remoteDaemon
        )

        let transport = factory.makeTransport(
            host: host,
            credentials: TerminalSSHCredentials(password: "secret", privateKey: nil),
            sessionName: "demo",
            resumeState: nil
        )

        XCTAssertTrue(transport === expectedTransport)
    }

    func testConnectAttachesExistingSessionAndTracksReadOffset() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                capabilities: ["terminal.stream"]
            ),
            attachResult: .success(
                .init(
                    sessionID: "sess-existing",
                    attachments: [],
                    effectiveCols: 100,
                    effectiveRows: 30,
                    lastKnownCols: 100,
                    lastKnownRows: 30
                )
            ),
            openResult: .init(
                sessionID: "sess-opened",
                attachmentID: "att-opened",
                attachments: [],
                effectiveCols: 100,
                effectiveRows: 30,
                lastKnownCols: 100,
                lastKnownRows: 30,
                offset: 0
            ),
            readResults: [
                .success(
                    .init(
                        sessionID: "sess-existing",
                        offset: 9,
                        baseOffset: 0,
                        truncated: false,
                        eof: false,
                        data: Data("resume".utf8)
                    )
                )
            ]
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo",
            resumeState: .init(sessionID: "sess-existing", attachmentID: "att-existing", readOffset: 3)
        )

        let connectedExpectation = expectation(description: "connected")
        let outputExpectation = expectation(description: "output")
        transport.eventHandler = { event in
            switch event {
            case .connected:
                connectedExpectation.fulfill()
            case .output(let data) where data == Data("resume".utf8):
                outputExpectation.fulfill()
            default:
                break
            }
        }

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 100, rows: 30))
        await fulfillment(of: [connectedExpectation, outputExpectation], timeout: 1.0)

        let attachCalls = await client.recordedAttaches()
        let openedCommands = await client.openedCommands()
        XCTAssertEqual(attachCalls.count, 1)
        XCTAssertEqual(attachCalls.first?.sessionID, "sess-existing")
        XCTAssertEqual(attachCalls.first?.attachmentID, "att-existing")
        XCTAssertEqual(openedCommands, [])
        XCTAssertEqual(
            transport.remoteDaemonResumeStateSnapshot(),
            .init(sessionID: "sess-existing", attachmentID: "att-existing", readOffset: 9)
        )

        await transport.disconnect()
        XCTAssertNil(transport.remoteDaemonResumeStateSnapshot())
    }

    func testConnectOpensFreshTerminalWhenStoredSessionIsGone() async throws {
        let client = StubDaemonSessionClient(
            hello: .init(
                name: "cmuxd-remote",
                version: "dev",
                capabilities: ["terminal.stream"]
            ),
            attachResult: .failure(
                TerminalRemoteDaemonClientError.rpc(code: "not_found", message: "session not found")
            ),
            openResult: .init(
                sessionID: "sess-new",
                attachmentID: "att-new",
                attachments: [],
                effectiveCols: 100,
                effectiveRows: 30,
                lastKnownCols: 100,
                lastKnownRows: 30,
                offset: 0
            ),
            readResults: []
        )
        let transport = TerminalRemoteDaemonSessionTransport(
            client: client,
            command: "tmux new-session -A -s demo",
            resumeState: .init(sessionID: "sess-stale", attachmentID: "att-stale", readOffset: 4)
        )

        try await transport.connect(initialSize: TerminalGridSize.fixture(columns: 100, rows: 30))

        let attachCalls = await client.recordedAttaches()
        let openedCommands = await client.openedCommands()
        XCTAssertEqual(attachCalls.count, 1)
        XCTAssertEqual(attachCalls.first?.sessionID, "sess-stale")
        XCTAssertEqual(openedCommands, ["tmux new-session -A -s demo"])
        XCTAssertEqual(
            transport.remoteDaemonResumeStateSnapshot(),
            .init(sessionID: "sess-new", attachmentID: "att-new", readOffset: 0)
        )

        await transport.disconnect()
    }
}

private actor StubDaemonSessionClient: TerminalRemoteDaemonSessionClient {
    private let hello: TerminalRemoteDaemonHello
    private let attachResult: Result<TerminalRemoteDaemonSessionStatus, Error>?
    private let openResult: TerminalRemoteDaemonTerminalOpenResult
    private var readResults: [Result<TerminalRemoteDaemonTerminalReadResult, Error>]
    private var openedCommandValues: [String] = []
    private var attachValues: [(sessionID: String, attachmentID: String, cols: Int, rows: Int)] = []
    private var detachValues: [(sessionID: String, attachmentID: String)] = []
    private var writeValues: [Data] = []
    private var resizeValues: [(sessionID: String, attachmentID: String, cols: Int, rows: Int)] = []
    private var closedSessionValues: [String] = []

    init(
        hello: TerminalRemoteDaemonHello,
        attachResult: Result<TerminalRemoteDaemonSessionStatus, Error>? = nil,
        openResult: TerminalRemoteDaemonTerminalOpenResult,
        readResults: [Result<TerminalRemoteDaemonTerminalReadResult, Error>]
    ) {
        self.hello = hello
        self.attachResult = attachResult
        self.openResult = openResult
        self.readResults = readResults
    }

    func sendHello() async throws -> TerminalRemoteDaemonHello {
        hello
    }

    func sessionAttach(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonSessionStatus {
        attachValues.append((sessionID, attachmentID, cols, rows))
        guard let attachResult else {
            throw TerminalRemoteDaemonClientError.rpc(code: "not_found", message: "session not found")
        }
        return try attachResult.get()
    }

    func terminalOpen(
        command: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonTerminalOpenResult {
        openedCommandValues.append(command)
        return openResult
    }

    func terminalWrite(sessionID: String, data: Data) async throws {
        writeValues.append(data)
    }

    func terminalRead(
        sessionID: String,
        offset: UInt64,
        maxBytes: Int,
        timeoutMilliseconds: Int
    ) async throws -> TerminalRemoteDaemonTerminalReadResult {
        guard !readResults.isEmpty else {
            throw TerminalRemoteDaemonClientError.rpc(
                code: "deadline_exceeded",
                message: "terminal read timed out"
            )
        }
        return try readResults.removeFirst().get()
    }

    func sessionResize(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonSessionStatus {
        resizeValues.append((sessionID, attachmentID, cols, rows))
        return .init(
            sessionID: sessionID,
            attachments: [],
            effectiveCols: cols,
            effectiveRows: rows,
            lastKnownCols: cols,
            lastKnownRows: rows
        )
    }

    func sessionDetach(sessionID: String, attachmentID: String) async throws -> TerminalRemoteDaemonSessionStatus {
        detachValues.append((sessionID, attachmentID))
        return .init(
            sessionID: sessionID,
            attachments: [],
            effectiveCols: 0,
            effectiveRows: 0,
            lastKnownCols: 0,
            lastKnownRows: 0
        )
    }

    func sessionClose(sessionID: String) async throws {
        closedSessionValues.append(sessionID)
    }

    func openedCommands() -> [String] {
        openedCommandValues
    }

    func recordedAttaches() -> [(sessionID: String, attachmentID: String, cols: Int, rows: Int)] {
        attachValues
    }

    func recordedWrites() -> [Data] {
        writeValues
    }

    func recordedResizes() -> [(sessionID: String, attachmentID: String, cols: Int, rows: Int)] {
        resizeValues
    }

    func recordedDetaches() -> [(sessionID: String, attachmentID: String)] {
        detachValues
    }

    func closedSessions() -> [String] {
        closedSessionValues
    }
}

private final class StubTerminalTransport: TerminalTransport {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    func connect(initialSize: TerminalGridSize) async throws {}
    func send(_ data: Data) async throws {}
    func resize(_ size: TerminalGridSize) async {}
    func disconnect() async {}
}

private extension TerminalGridSize {
    static func fixture(columns: Int, rows: Int) -> Self {
        .init(columns: columns, rows: rows, pixelWidth: columns * 10, pixelHeight: rows * 20)
    }
}
