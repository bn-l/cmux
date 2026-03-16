import XCTest
@testable import cmux_DEV

final class TerminalServerCatalogTests: XCTestCase {
    func testCatalogDecodesTeamServerMetadata() throws {
        let json = """
        {
          "cmux": {
            "servers": [
              {
                "id": "cmux-macmini",
                "name": "Mac mini",
                "hostname": "cmux-macmini",
                "port": 22,
                "username": "cmux",
                "symbolName": "desktopcomputer",
                "palette": "mint",
                "transport": "cmuxd-remote",
                "direct_tls_pins": ["sha256:pin-a", "sha256:pin-b"]
              }
            ]
          }
        }
        """

        let catalog = try TerminalServerCatalog(metadataJSON: json, teamID: "team-1")

        XCTAssertEqual(catalog.hosts.map(\.stableID), ["cmux-macmini"])
        XCTAssertEqual(catalog.hosts.first?.transportPreference, .remoteDaemon)
        XCTAssertEqual(catalog.hosts.first?.source, .discovered)
        XCTAssertEqual(catalog.hosts.first?.teamID, "team-1")
        XCTAssertEqual(catalog.hosts.first?.serverID, "cmux-macmini")
        XCTAssertEqual(catalog.hosts.first?.directTLSPins, ["sha256:pin-a", "sha256:pin-b"])
    }

    func testMergePreservesLocalSecretsAndExistingWorkspaceHostIDs() {
        let discovered = [
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini",
                allowsSSHFallback: false,
                directTLSPins: ["sha256:new-pin"]
            )
        ]

        let preservedID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let local = [
            TerminalHost(
                id: preservedID,
                stableID: "cmux-macmini",
                name: "Old Label",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                bootstrapCommand: "tmux new-session -A -s {{session}}",
                trustedHostKey: "ssh-ed25519 AAAA",
                sortIndex: 4,
                source: .discovered,
                transportPreference: .rawSSH,
                directTLSPins: ["sha256:old-pin"]
            )
        ]

        let merged = TerminalServerCatalog.merge(discovered: discovered, local: local)

        XCTAssertEqual(merged.first?.id, preservedID)
        XCTAssertEqual(merged.first?.trustedHostKey, "ssh-ed25519 AAAA")
        XCTAssertEqual(merged.first?.sortIndex, 4)
        XCTAssertEqual(merged.first?.transportPreference, .remoteDaemon)
        XCTAssertEqual(merged.first?.name, "Mac mini")
        XCTAssertEqual(merged.first?.teamID, "team-1")
        XCTAssertEqual(merged.first?.serverID, "cmux-macmini")
        XCTAssertEqual(merged.first?.allowsSSHFallback, false)
        XCTAssertEqual(merged.first?.directTLSPins, ["sha256:new-pin"])
    }

    func testMergePreservesLocalSSHAuthenticationMethodForDiscoveredHosts() {
        let discovered = [
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini"
            )
        ]

        let local = [
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                source: .discovered,
                transportPreference: .rawSSH,
                sshAuthenticationMethod: .privateKey
            )
        ]

        let merged = TerminalServerCatalog.merge(discovered: discovered, local: local)

        XCTAssertEqual(merged.first?.sshAuthenticationMethod, .privateKey)
    }

    func testMergePreservesLocalBootstrapCommandForDiscoveredHosts() {
        let discovered = [
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                bootstrapCommand: "tmux new-session -A -s {{session}}",
                source: .discovered,
                transportPreference: .remoteDaemon,
                teamID: "team-1",
                serverID: "cmux-macmini"
            )
        ]

        let local = [
            TerminalHost(
                stableID: "cmux-macmini",
                name: "Mac mini",
                hostname: "cmux-macmini",
                username: "cmux",
                symbolName: "desktopcomputer",
                palette: .mint,
                bootstrapCommand: "cmux attach --workspace {{session}}",
                source: .discovered,
                transportPreference: .remoteDaemon
            )
        ]

        let merged = TerminalServerCatalog.merge(discovered: discovered, local: local)

        XCTAssertEqual(merged.first?.bootstrapCommand, "cmux attach --workspace {{session}}")
    }

    func testCatalogNormalizesDirectTLSPinsFromMetadata() throws {
        let json = """
        {
          "cmux": {
            "servers": [
              {
                "id": "cmux-macmini",
                "name": "Mac mini",
                "hostname": "cmux-macmini",
                "username": "cmux",
                "transport": "cmuxd-remote",
                "direct_tls_pins": [" sha256:pin-a ", "", "sha256:pin-a", "sha256:pin-b "]
              }
            ]
          }
        }
        """

        let catalog = try TerminalServerCatalog(metadataJSON: json, teamID: "team-1")

        XCTAssertEqual(catalog.hosts.first?.directTLSPins, ["sha256:pin-a", "sha256:pin-b"])
    }
}
