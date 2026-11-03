import Foundation
import Testing
@testable import CmuxControlSocket

#if DEBUG
/// A scriptable ``ControlDebugContext`` for driving the v1 debug dispatch
/// without the app target. Only the debug methods the v1 dispatch exercises are
/// overridden; the rest fall back to the benign defaults in
/// `ControlCommandContextTestStubs+Debug.swift`.
@MainActor
private final class FakeDebugV1ControlCommandContext: ControlCommandContext {
    var setShortcutArguments: String?
    var setShortcutResponse = "OK"

    func controlDebugSetShortcut(arguments: String) -> String {
        setShortcutArguments = arguments
        return setShortcutResponse
    }
}

@MainActor
@Suite("ControlCommandCoordinator debug v1 dispatch")
struct ControlCommandCoordinatorDebugV1Tests {
    private func makeCoordinator() -> (ControlCommandCoordinator, FakeDebugV1ControlCommandContext) {
        let context = FakeDebugV1ControlCommandContext()
        let coordinator = ControlCommandCoordinator(context: context)
        return (coordinator, context)
    }

    @Test func forwardsSetShortcutArgumentsVerbatim() {
        let (coordinator, context) = makeCoordinator()
        let reply = coordinator.handleDebugV1(command: "set_shortcut", args: "open-palette cmd+k")
        #expect(reply == "OK")
        #expect(context.setShortcutArguments == "open-palette cmd+k")
    }

    @Test func forwardsSetShortcutErrorVerbatim() {
        let (coordinator, context) = makeCoordinator()
        context.setShortcutResponse = "ERROR: Invalid shortcut"
        let reply = coordinator.handleDebugV1(command: "set_shortcut", args: "x")
        #expect(reply == "ERROR: Invalid shortcut")
    }

    @Test func unknownCommandFallsThrough() {
        let (coordinator, _) = makeCoordinator()
        #expect(coordinator.handleDebugV1(command: "ping", args: "") == nil)
        #expect(coordinator.handleDebugV1(command: "simulate_type", args: "hi") == nil)
    }
}
#endif
