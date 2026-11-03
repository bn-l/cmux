import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Socket-level tests for `feed.push` after the Feed removal: the app takes an
/// agent hook event, publishes it, and answers at once. It never holds the
/// caller waiting for a decision, and the Feed reply/jump/list verbs are gone.
@MainActor
@Suite(.serialized)
struct FeedPushSocketTests {
    /// Sends one v2 request from a background thread, the way a socket worker
    /// does (`feed.push` hops to the main actor for its side effects, so a
    /// main-thread caller would deadlock).
    private func call(method: String, params: [String: Any]) async throws -> [String: Any] {
        let request: [String: Any] = ["id": "test-\(method)", "method": method, "params": params]
        let line = try #require(String(data: try JSONSerialization.data(withJSONObject: request), encoding: .utf8))
        let response = await Task.detached { TerminalController.shared.handleSocketLine(line) }.value
        let data = try #require(response.data(using: .utf8))
        return try #require(JSONSerialization.jsonObject(with: data) as? [String: Any], "\(response)")
    }

    /// An older CLI still sends `wait_timeout_seconds: 120` with an id for a
    /// permission prompt. The app must answer at once with an acknowledgement
    /// and no decision.
    @Test func permissionRequestIsAcknowledgedAtOnceEvenWhenTheCallerAsksToWait() async throws {
        // Arrange
        let sessionId = "feed-push-wait-\(UUID().uuidString)"
        let params: [String: Any] = [
            "event": [
                "session_id": sessionId,
                "hook_event_name": "PermissionRequest",
                "_source": "claude",
                "tool_name": "Bash",
                "tool_input": ["command": "rm -rf build"],
            ],
            "wait_timeout_seconds": 120,
        ]

        // Act
        let started = Date()
        let envelope = try await call(method: "feed.push", params: params)
        let elapsed = Date().timeIntervalSince(started)

        // Assert
        #expect(envelope["ok"] as? Bool == true, "\(envelope)")
        let result = try #require(envelope["result"] as? [String: Any], "\(envelope)")
        #expect(result as NSDictionary == ["status": "acknowledged"] as NSDictionary, "no decision may come back: \(result)")
        #expect(elapsed < 2, "feed.push held the caller for \(elapsed)s")
    }

    @Test func malformedPushIsRejected() async throws {
        let envelope = try await call(method: "feed.push", params: ["event": ["session_id": "no-name"]])

        #expect(envelope["ok"] as? Bool == false, "\(envelope)")
        #expect((envelope["error"] as? [String: Any])?["code"] as? String == "invalid_params")
    }

    @Test(arguments: [
        "feed.permission.reply",
        "feed.question.reply",
        "feed.exit_plan.reply",
        "feed.jump",
        "feed.list",
    ])
    func removedFeedVerbsAreUnknownMethods(method: String) async throws {
        let envelope = try await call(method: method, params: [
            "request_id": "req-1",
            "mode": "deny",
            "selections": ["a"],
            "workstream_id": "claude-x",
        ])

        #expect(envelope["ok"] as? Bool == false, "\(method): \(envelope)")
        #expect((envelope["error"] as? [String: Any])?["code"] as? String == "method_not_found", "\(method): \(envelope)")
    }

    @Test func capabilitiesNoLongerAdvertiseFeedReplyVerbs() async throws {
        let envelope = try await call(method: "system.capabilities", params: [:])
        let result = try #require(envelope["result"] as? [String: Any], "\(envelope)")
        let methods = try #require(result["methods"] as? [String], "\(result.keys)")

        #expect(methods.contains("feed.push"))
        #expect(methods.filter { $0.hasPrefix("feed.") } == ["feed.push"], "\(methods.filter { $0.hasPrefix("feed.") })")
    }
}
