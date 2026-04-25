import XCTest
import Combine

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Regression test for the 2026-04-03 SwiftUI layout death-spiral fix
/// (DEVLOG.md:15). High-frequency telemetry (`report_git_branch`,
/// `report_ports`, `report_pwd`) used to reassign `@Published` dictionaries
/// unconditionally, firing `objectWillChange` on every socket call even when
/// the value was unchanged. With 19 mounted workspaces and sustained
/// telemetry traffic, the resulting invalidation storm beachballed the app.
///
/// The fix was two-fold:
///  - a caller-side equality guard on hot telemetry dictionaries, now
///    expressed as the `Workspace.setSurfaceListeningPorts(_:for:)` helper
///    used by both the port scanner and the `report_ports` socket command.
///  - `pruneSurfaceMetadata` only reassigns the 7 sidebar dictionaries when
///    stale keys actually exist.
///
/// These tests drive the real production mutator so a regression that
/// deletes the guard inside the helper (or a caller that bypasses the
/// helper and assigns the `@Published` dictionary directly) is caught here.
@MainActor
final class SidebarObjectWillChangeRateTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    private func makeWorkspace() -> Workspace {
        Workspace(title: "Test")
    }

    private func subscribeAndCount(_ workspace: Workspace) -> (() -> Int) {
        var count = 0
        workspace.objectWillChange
            .sink { _ in count += 1 }
            .store(in: &cancellables)
        return { count }
    }

    /// Drives the production helper used by both `report_ports` and the
    /// PortScanner callback. A regression that deletes the `==` guard inside
    /// `setSurfaceListeningPorts` causes repeated identical writes to
    /// republish — this test would then fail at the `readCount() == 1`
    /// assertion. (Previously this test re-implemented the guard in the test
    /// body, which meant it couldn't catch a production regression — the
    /// test's own inline guard would mask it.)
    func testSetSurfaceListeningPortsDoesNotRepublishForIdenticalValue() {
        let workspace = makeWorkspace()
        let readCount = subscribeAndCount(workspace)
        let surfaceId = UUID()
        let ports = [8080, 3000]

        XCTAssertTrue(workspace.setSurfaceListeningPorts(ports, for: surfaceId),
                      "first write must report changed=true")
        XCTAssertEqual(readCount(), 1,
                       "initial assignment must publish exactly once")

        let repeats = 50
        for _ in 0..<repeats {
            XCTAssertFalse(workspace.setSurfaceListeningPorts(ports, for: surfaceId),
                           "identical write must report changed=false")
        }
        XCTAssertEqual(readCount(), 1,
                       "identical writes through the helper must not republish")

        XCTAssertTrue(workspace.setSurfaceListeningPorts([9090], for: surfaceId),
                      "genuine change must report changed=true")
        XCTAssertEqual(readCount(), 2)

        XCTAssertTrue(workspace.setSurfaceListeningPorts(nil, for: surfaceId),
                      "removal must report changed=true")
        XCTAssertEqual(readCount(), 3)
        XCTAssertNil(workspace.surfaceListeningPorts[surfaceId],
                     "nil must remove the key")

        XCTAssertFalse(workspace.setSurfaceListeningPorts(nil, for: surfaceId),
                       "removing an already-absent key must report changed=false")
        XCTAssertEqual(readCount(), 3)
    }

    /// Counter-example: a caller that bypasses the helper and writes the
    /// @Published dictionary directly re-publishes on every assignment, even
    /// for equal values. This documents that @Published itself does NOT
    /// coalesce — the helper is what saves us. If the language/stdlib ever
    /// changes so @Published coalesces, this test will fail and every other
    /// guard-based assumption in the codebase needs re-review.
    func testDirectAssignmentBypassesTheGuardAndAlwaysPublishes() {
        let workspace = makeWorkspace()
        let readCount = subscribeAndCount(workspace)
        let surfaceId = UUID()
        let ports = [8080, 3000]

        for _ in 0..<10 {
            // Intentionally bypass the helper — simulates a regression
            // where a new telemetry caller forgets to use the helper.
            workspace.surfaceListeningPorts[surfaceId] = ports
        }
        XCTAssertEqual(readCount(), 10,
                       "@Published always publishes on direct set; the helper is "
                       + "what suppresses no-op republishes")
    }

    /// `pruneSurfaceMetadata` is called from every panel-metadata mutation.
    /// Before the DEVLOG:15 fix it unconditionally reassigned its 7 sidebar
    /// dictionaries via `.filter()` even when no surface ids were stale,
    /// producing an objectWillChange per call. Lock in the guard: calling
    /// prune with a matching live set produces no publish.
    func testPruneSurfaceMetadataIsNoOpWhenNoStaleKeys() {
        let workspace = makeWorkspace()
        let surfaceId = UUID()
        workspace.setSurfaceListeningPorts([8080], for: surfaceId)
        let readCount = subscribeAndCount(workspace)

        let validSet: Set<UUID> = [surfaceId]
        for _ in 0..<20 {
            workspace.pruneSurfaceMetadata(validSurfaceIds: validSet)
        }

        XCTAssertEqual(readCount(), 0,
                       "pruneSurfaceMetadata must be a no-op when nothing is stale")
    }
}
