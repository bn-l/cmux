import Foundation

/// Maps a raw agent hook event to the wire `hook_event_name` that
/// `cmux hooks feed` forwards to the app, where it feeds the workspace prompt
/// record, Jump to Last Prompt and the `agent.hook.*` events stream.
///
/// cmux never holds an agent or answers for it, so the mapping carries no
/// "actionable" flag: every event is fire-and-forget telemetry.
///
/// The file is compiled into the `cmux-cli` target and the `cmuxTests`
/// target so the mapping can be unit-tested without running the CLI.
struct FeedEventClassifier {
    /// The wire `hook_event_name` for an agent's raw hook event.
    ///
    /// - Parameters:
    ///   - source: The agent id that emitted the event (`claude`, `codex`,
    ///     `hermes-agent`, …). Unregistered sources use the generic table.
    ///   - event: The agent's raw hook event name.
    static func wireEventName(source: String, event: String) -> String {
        let table = feedEventSemanticRegistry[source] ?? genericFeedEventSemantics
        return (table[event] ?? .unknown).wireName
    }

    /// What a hook event means, independent of the agent-specific raw name.
    private enum FeedEventSemantic {
        /// The agent is showing its own approval prompt.
        case approvalRequest
        /// A tool is about to run.
        case toolStart
        /// A tool finished.
        case toolEnd
        /// The agent is about to compact conversation context.
        case preCompact
        /// The agent finished compacting conversation context.
        case postCompact
        /// A new turn / prompt started.
        case promptSubmit
        /// A subagent started.
        case subagentStart
        /// The agent finished responding.
        case response
        /// A subagent finished responding.
        case subagentResponse
        case sessionStart
        case sessionEnd
        /// A generic status/notification event.
        case statusNotification
        /// Unknown / unregistered event.
        case unknown

        var wireName: String {
            switch self {
            case .approvalRequest: return "PermissionRequest"
            case .toolStart, .unknown: return "PreToolUse"
            case .toolEnd: return "PostToolUse"
            case .preCompact: return "PreCompact"
            case .postCompact: return "PostCompact"
            case .promptSubmit: return "UserPromptSubmit"
            case .subagentStart: return "SubagentStart"
            case .response: return "Stop"
            case .subagentResponse: return "SubagentStop"
            case .sessionStart: return "SessionStart"
            case .sessionEnd: return "SessionEnd"
            case .statusNotification: return "Notification"
            }
        }
    }

    /// Per-agent event-semantic tables. Each entry is the source of truth
    /// for that agent's `(event) -> semantic` mapping; events absent here
    /// resolve to ``FeedEventSemantic/unknown``.
    private static let feedEventSemanticRegistry: [String: [String: FeedEventSemantic]] = [
        "claude": [
            "PermissionRequest": .approvalRequest,
            "PreToolUse": .toolStart,
            "PostToolUse": .toolEnd,
            "PreCompact": .preCompact,
            "PostCompact": .postCompact,
            "UserPromptSubmit": .promptSubmit,
            "SessionStart": .sessionStart,
            "SessionEnd": .sessionEnd,
            "Stop": .response,
            "SubagentStart": .subagentStart,
            "SubagentStop": .subagentResponse,
            "Notification": .statusNotification,
        ],
        "codex": [
            "PermissionRequest": .toolStart,
            "permission_request": .toolStart,
            "PreToolUse": .toolStart,
            "pre_tool_use": .toolStart,
            "beforeShellExecution": .toolStart,
            "PostToolUse": .toolEnd,
            "post_tool_use": .toolEnd,
            "PreCompact": .preCompact,
            "pre_compact": .preCompact,
            "PostCompact": .postCompact,
            "post_compact": .postCompact,
            "UserPromptSubmit": .promptSubmit,
            "user_prompt_submit": .promptSubmit,
            "SessionStart": .sessionStart,
            "session_start": .sessionStart,
            "SessionEnd": .sessionEnd,
            "session_end": .sessionEnd,
            "Stop": .response,
            "stop": .response,
            "SubagentStart": .subagentStart,
            "subagent_start": .subagentStart,
            "SubagentStop": .subagentResponse,
            "subagent_stop": .subagentResponse,
            "Notification": .statusNotification,
            "notification": .statusNotification,
        ],
        "hermes-agent": [
            "pre_tool_call": .toolStart,
            "post_tool_call": .toolEnd,
            "pre_approval_request": .statusNotification,
            "post_approval_response": .statusNotification,
            "pre_llm_call": .promptSubmit,
            "post_llm_call": .response,
            "on_session_start": .sessionStart,
            "on_session_reset": .sessionStart,
            "on_session_end": .sessionEnd,
            "on_session_finalize": .sessionEnd,
        ],
        // Kiro emits camelCase hook events, absent from
        // ``genericFeedEventSemantics``.
        "kiro": [
            "preToolUse": .toolStart,
            "postToolUse": .toolEnd,
            "userPromptSubmit": .promptSubmit,
            "agentSpawn": .sessionStart,
            "stop": .response,
        ],
    ]

    /// Fallback table for agents without a dedicated entry in
    /// ``feedEventSemanticRegistry``.
    private static let genericFeedEventSemantics: [String: FeedEventSemantic] = [
        "PreToolUse": .toolStart,
        "beforeShellExecution": .toolStart,
        "PermissionRequest": .approvalRequest,
        "PostToolUse": .toolEnd,
        "PreCompact": .preCompact,
        "PostCompact": .postCompact,
        "UserPromptSubmit": .promptSubmit,
        "SessionStart": .sessionStart,
        "SessionEnd": .sessionEnd,
        "Stop": .response,
        "SubagentStart": .subagentStart,
        "SubagentStop": .subagentResponse,
        "Notification": .statusNotification,
    ]
}
