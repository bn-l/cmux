import Testing

// `FeedEventClassifier` lives in `CLI/FeedEventClassifier.swift`, which is
// compiled into both the `cmux-cli` target and this test target — so the pure
// mapping can be unit-tested directly, without `@testable` importing the
// `cmux_cli` executable module (whose symbols the app-hosted test bundle
// cannot link).

/// Coverage for the raw agent hook event → wire `hook_event_name` mapping that
/// `cmux hooks feed` forwards. The wire name drives the workspace prompt record
/// and Jump to Last Prompt (`UserPromptSubmit`) and the `agent.hook.<name>`
/// events stream, so a wrong mapping silently breaks those.
///
/// The mapping no longer depends on the tool name: cmux never turns a tool
/// start into an approval it holds (https://github.com/manaflow-ai/cmux/issues/4985
/// was the over-triggering this used to guard).
@Suite("Feed event wire names")
struct FeedEventClassificationTests {
    private func wire(_ source: String, _ event: String) -> String {
        FeedEventClassifier.wireEventName(source: source, event: event)
    }

    @Test func promptAndStopEventsMapForEveryRegisteredAgent() {
        #expect(wire("claude", "UserPromptSubmit") == "UserPromptSubmit")
        #expect(wire("claude", "Stop") == "Stop")
        #expect(wire("codex", "user_prompt_submit") == "UserPromptSubmit")
        #expect(wire("codex", "stop") == "Stop")
        #expect(wire("hermes-agent", "pre_llm_call") == "UserPromptSubmit")
        #expect(wire("hermes-agent", "post_llm_call") == "Stop")
        #expect(wire("kiro", "userPromptSubmit") == "UserPromptSubmit")
        #expect(wire("kiro", "stop") == "Stop")
        #expect(wire("gemini", "UserPromptSubmit") == "UserPromptSubmit")
        #expect(wire("gemini", "Stop") == "Stop")
    }

    /// A tool start is a tool start for every agent, whatever the tool.
    /// Before the Feed removal, generic and Kiro pre-tool events for
    /// side-effecting tools were rewritten to `PermissionRequest` and held.
    @Test func toolStartsAreNeverRewrittenToApprovals() {
        #expect(wire("gemini", "PreToolUse") == "PreToolUse")
        #expect(wire("copilot", "beforeShellExecution") == "PreToolUse")
        #expect(wire("kiro", "preToolUse") == "PreToolUse")
        #expect(wire("hermes-agent", "pre_tool_call") == "PreToolUse")
        #expect(wire("claude", "PreToolUse") == "PreToolUse")
    }

    /// Codex runs `PermissionRequest` hooks before its own approval reviewer;
    /// it is forwarded as a plain tool start.
    @Test func codexPermissionRequestIsAToolStart() {
        #expect(wire("codex", "PermissionRequest") == "PreToolUse")
        #expect(wire("codex", "permission_request") == "PreToolUse")
        #expect(wire("codex", "beforeShellExecution") == "PreToolUse")
    }

    /// Hermes approval events are status notifications, not approvals.
    @Test func hermesApprovalEventsAreNotifications() {
        #expect(wire("hermes-agent", "pre_approval_request") == "Notification")
        #expect(wire("hermes-agent", "post_approval_response") == "Notification")
    }

    @Test func lifecycleEventsPreserveTheirNames() {
        for event in ["PostToolUse", "PreCompact", "PostCompact", "SubagentStart", "SubagentStop"] {
            #expect(wire("claude", event) == event)
            #expect(wire("codex", event) == event)
            #expect(wire("gemini", event) == event)
        }
    }

    @Test func codexSnakeCaseLifecycleEventsMapToWireNames() {
        let cases = [
            ("post_tool_use", "PostToolUse"),
            ("pre_compact", "PreCompact"),
            ("post_compact", "PostCompact"),
            ("subagent_start", "SubagentStart"),
            ("subagent_stop", "SubagentStop"),
            ("session_start", "SessionStart"),
            ("session_end", "SessionEnd"),
        ]
        for (event, expected) in cases {
            #expect(wire("codex", event) == expected, "\(event)")
        }
    }

    /// Kiro's camelCase names are absent from the generic table; without its
    /// own entry they would all collapse to the unknown fallback.
    @Test func kiroCamelCaseEventsMapToWireNames() {
        #expect(wire("kiro", "postToolUse") == "PostToolUse")
        #expect(wire("kiro", "agentSpawn") == "SessionStart")
    }

    /// Unknown events fall back to a plain tool start, never an approval.
    @Test func unknownEventsFallBackToToolStart() {
        #expect(wire("totally-new-agent", "some_future_event") == "PreToolUse")
        #expect(wire("hermes-agent", "some_future_event") == "PreToolUse")
        #expect(wire("kiro", "PreToolUse") == "PreToolUse")
    }
}
