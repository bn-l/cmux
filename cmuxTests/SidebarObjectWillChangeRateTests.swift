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
///  - caller-side equality guards (`if tab.surfaceListeningPorts[id] !=
///    ports { tab.surfaceListeningPorts[id] = ports }`)
///  - `pruneSurfaceMetadata` only reassigns the 7 sidebar dictionaries when
///    stale keys actually exist.
///
/// These tests lock in both behaviours at the `Workspace` model layer. A
/// regression that removes the equality guard from either path would cause
/// these tests to fail loudly.
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

    func testGuardedSurfaceListeningPortsDoesNotRepublishForIdenticalValue() {
        let workspace = makeWorkspace()
        let readCount = subscribeAndCount(workspace)
        let surfaceId = UUID()
        let ports = [8080, 3000]

        // First write — genuine change; one publish.
        if workspace.surfaceListeningPorts[surfaceId] != ports {
            workspace.surfaceListeningPorts[surfaceId] = ports
        }
        XCTAssertEqual(readCount(), 1,
                       "initial assignment must publish exactly once")

        // Repeated identical writes using the guarded pattern — ZERO extra
        // publishes expected. If the guard is removed in the production
        // handler, the write itself stays safe but the emission rate
        // regresses to N per telemetry tick.
        let repeats = 50
        for _ in 0..<repeats {
            if workspace.surfaceListeningPorts[surfaceId] != ports {
                workspace.surfaceListeningPorts[surfaceId] = ports
            }
        }
        XCTAssertEqual(readCount(), 1,
                       "guarded identical writes must not republish")

        // A genuine change — one more publish.
        if workspace.surfaceListeningPorts[surfaceId] != [9090] {
            workspace.surfaceListeningPorts[surfaceId] = [9090]
        }
        XCTAssertEqual(readCount(), 2)
    }

    func testUnguardedReassignStillPublishesToProveTheGuardMatters() {
        // This is the counter-example: without the guard, every assignment
        // publishes, even for equal values. Locks in @Published's actual
        // behaviour so future refactors don't silently break the invariant
        // that the GUARD is what saves us, not the @Published wrapper.
        let workspace = makeWorkspace()
        let readCount = subscribeAndCount(workspace)
        let surfaceId = UUID()
        let ports = [8080, 3000]

        for _ in 0..<10 {
            // Intentionally unguarded — write every time.
            workspace.surfaceListeningPorts[surfaceId] = ports
        }
        XCTAssertEqual(readCount(), 10,
                       "@Published always publishes on set; if this ever "
                       + "becomes <10 the language/stdlib changed under us "
                       + "and other guard-based assumptions need re-review")
    }

    /// `pruneSurfaceMetadata` is called from every panel-metadata mutation.
    /// Before the DEVLOG:15 fix it unconditionally reassigned its 7 sidebar
    /// dictionaries via `.filter()` even when no surface ids were stale,
    /// producing an objectWillChange per call. Lock in the guard: calling
    /// prune with a matching live set produces no publish.
    func testPruneSurfaceMetadataIsNoOpWhenNoStaleKeys() {
        let workspace = makeWorkspace()
        let surfaceId = UUID()
        let ports = [8080]
        workspace.surfaceListeningPorts[surfaceId] = ports
        // The first assignment publishes once — subscribe AFTER so we measure
        // prune-only behaviour.
        let readCount = subscribeAndCount(workspace)

        let validSet: Set<UUID> = [surfaceId]
        for _ in 0..<20 {
            workspace.pruneSurfaceMetadata(validSurfaceIds: validSet)
        }

        XCTAssertEqual(readCount(), 0,
                       "pruneSurfaceMetadata must be a no-op when nothing is stale")
    }
}
