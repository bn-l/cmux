import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class TerminalBackendContractsTests: XCTestCase {
    func testBackendIdentityRoundTripsThroughJSON() throws {
        let identity = TerminalWorkspaceBackendIdentity(
            teamID: "team_123",
            taskID: "task_456",
            taskRunID: "task_run_789",
            workspaceName: "Mac mini",
            descriptor: "cmux@cmux-macmini"
        )

        let data = try JSONEncoder().encode(identity)
        let decoded = try JSONDecoder().decode(TerminalWorkspaceBackendIdentity.self, from: data)

        XCTAssertEqual(decoded, identity)
    }

    func testBackendMetadataRoundTripsThroughJSON() throws {
        let metadata = TerminalWorkspaceBackendMetadata(preview: "feature/direct-daemon")

        let data = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(TerminalWorkspaceBackendMetadata.self, from: data)

        XCTAssertEqual(decoded, metadata)
    }
}
