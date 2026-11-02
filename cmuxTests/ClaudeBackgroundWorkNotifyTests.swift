import Dispatch
import Foundation
import Testing

/// Behavioral coverage for the agent-notification gating signal the Claude hook
/// forwards to the app: the `notify_target_async` payload's `c=<category>;p=<0|1>`
/// meta segment, and the `hadPendingBackgroundWorkAtStop` cache the idle_prompt
/// path reads. Drives the real CLI against the mock socket server, exactly like
/// `ClaudeNotificationStatusLifecycleTests`.
@Suite(.serialized)
struct ClaudeBackgroundWorkNotifyTests {
    private func notifyLine(_ snapshot: [String], containing needle: String) -> String? {
        snapshot.first { $0.hasPrefix("notify_target_async ") && $0.contains(needle) }
    }

    private func statusLine(_ snapshot: [String], value: String) -> String? {
        snapshot.first { $0.hasPrefix("set_status claude_code \(value) ") }
    }

    private func lifecycleLine(_ snapshot: [String], value: String) -> String? {
        snapshot.first { $0.hasPrefix("set_agent_lifecycle claude_code \(value) ") }
    }

    private func runStopHook(
        name: String,
        sessionId: String,
        stdin: String
    ) throws -> (snapshot: [String], cachedPending: Bool?) {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: name)
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-\(name)",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-\(name)",
            storeURL: storeURL
        )
        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: stdin,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)
        let snapshot = context.state.snapshot()
        // Read the cached flag from the store BEFORE cleanup deletes the temp dir.
        let cached = cachedPending(storeURL, sessionId: sessionId)
        context.cleanup()
        return (snapshot, cached)
    }

    private func cachedPending(_ storeURL: URL, sessionId: String) -> Bool? {
        storeRecord(storeURL, sessionId: sessionId)?["hadPendingBackgroundWorkAtStop"] as? Bool
    }

    private func storedLifecycle(_ storeURL: URL, sessionId: String) -> String? {
        storeRecord(storeURL, sessionId: sessionId)?["agentLifecycle"] as? String
    }

    private func storeRecord(_ storeURL: URL, sessionId: String) -> [String: Any]? {
        guard let data = try? Data(contentsOf: storeURL),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let sessions = obj["sessions"] as? [String: Any] else { return nil }
        return sessions[sessionId] as? [String: Any]
    }

    /// Runs a sequence of hook calls for one Claude session against one mock
    /// socket server and one hook store, so later hooks see what earlier ones wrote.
    private struct HookSession {
        let session: String
        let run: (_ subcommand: String, _ payload: String) -> Void
        let snapshot: () -> [String]
        let record: () -> [String: Any]?

        var lifecycle: String? { record()?["agentLifecycle"] as? String }
        var turnSettled: Bool? { record()?["turnSettled"] as? Bool }

        var prompt: String { #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"UserPromptSubmit","prompt":"finish this"}"# }
        var helperTool: String { #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":"git status"}}"# }
        func stop(pendingWork: Bool) -> String {
            let tasks = pendingWork ? #"[{"id":"t1","type":"shell","status":"running","description":"build","command":"sleep 1"}]"# : "[]"
            return #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"done","background_tasks":\#(tasks),"session_crons":[]}"#
        }
        var permissionPrompt: String { #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Notification","notification_type":"permission_prompt","message":"Claude needs your permission"}"# }
    }

    private func withHookSession(name: String, _ body: (HookSession) throws -> Void) throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: name)
        defer { context.cleanup() }
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-\(name)",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-\(name)",
            storeURL: storeURL
        )
        let session = "\(name)-session"
        try body(HookSession(
            session: session,
            run: { subcommand, payload in
                let result = harness.runProcess(
                    executablePath: context.cliPath,
                    arguments: ["hooks", "claude", subcommand],
                    environment: environment,
                    standardInput: payload,
                    timeout: 5
                )
                #expect(handled.wait(timeout: .now() + 5) == .success)
                harness.assertSuccessfulHook(result)
            },
            snapshot: { context.state.snapshot() },
            record: { self.storeRecord(storeURL, sessionId: session) }
        ))
    }

    // MARK: - A finished subagent mid-turn (upstream #10343)

    /// `agent_completed` is Claude Code's user-facing form of SubagentStop: a Task
    /// subagent finished while the parent keeps working. Untyped older clients
    /// send the same thing as a "completed" message, which the cue classifier
    /// files under the same turn-complete category.
    @Test(arguments: [#","notification_type":"agent_completed"#, ""])
    func subagentCompletionLeavesPaneRunningWithoutPing(typeField: String) throws {
        try withHookSession(name: "subagent-done\(typeField.isEmpty ? "-untyped" : "")") { hooks in
            hooks.run("prompt-submit", hooks.prompt)
            let afterPrompt = hooks.snapshot().count
            hooks.run("notification", #"{"session_id":"\#(hooks.session)","cwd":"/tmp/x","hook_event_name":"Notification","message":"Agent code-reviewer completed"\#(typeField)}"#)
            let afterNotification = Array(hooks.snapshot().dropFirst(afterPrompt))

            #expect(statusLine(afterNotification, value: "Needs input") == nil,
                    "A finished subagent must not set the Needs input pill; saw \(afterNotification)")
            #expect(lifecycleLine(afterNotification, value: "needsInput") == nil, "saw \(afterNotification)")
            #expect(notifyLine(afterNotification, containing: "Agent code-reviewer completed") == nil,
                    "A finished subagent must not ping: the parent's Stop sends the one completion ping; saw \(afterNotification)")
            #expect(hooks.lifecycle == "running", "The parent is still mid-turn")
            let lastStatus = hooks.snapshot().last { $0.hasPrefix("set_status claude_code ") }
            #expect(lastStatus?.hasPrefix("set_status claude_code Running ") == true,
                    "The pane must be left Running; last status was \(String(describing: lastStatus))")
        }
    }

    @Test func subagentCompletionDoesNotSwallowTheParentStop() throws {
        try withHookSession(name: "subagent-then-stop") { hooks in
            hooks.run("prompt-submit", hooks.prompt)
            hooks.run("notification", #"{"session_id":"\#(hooks.session)","cwd":"/tmp/x","hook_event_name":"Notification","message":"Agent code-reviewer completed","notification_type":"agent_completed"}"#)
            hooks.run("stop", hooks.stop(pendingWork: false))
            let snapshot = hooks.snapshot()
            #expect(notifyLine(snapshot, containing: "c=turn-complete") != nil,
                    "The parent's Stop must still deliver the turn-complete ping; saw \(snapshot)")
            #expect(hooks.lifecycle == "idle")
            let lastStatus = snapshot.last { $0.hasPrefix("set_status claude_code ") }
            #expect(lastStatus?.hasPrefix("set_status claude_code Idle ") == true,
                    "The parent's Stop owns the turn-complete transition; last status was \(String(describing: lastStatus))")
        }
    }

    // MARK: - A helper's PreToolUse after Stop (upstream #20262)

    @Test func preToolUseAfterStopDoesNotReopenRunningState() throws {
        try withHookSession(name: "helper-after-stop") { hooks in
            hooks.run("prompt-submit", hooks.prompt)
            hooks.run("stop", hooks.stop(pendingWork: false))
            #expect(hooks.lifecycle == "idle")
            #expect(hooks.turnSettled == true)
            let afterStop = hooks.snapshot().count

            hooks.run("pre-tool-use", hooks.helperTool)
            let afterTool = Array(hooks.snapshot().dropFirst(afterStop))
            #expect(hooks.lifecycle == "idle", "A helper tool after Stop must not reopen the turn")
            #expect(statusLine(afterTool, value: "Running") == nil, "saw \(afterTool)")
            #expect(lifecycleLine(afterTool, value: "running") == nil, "saw \(afterTool)")

            // The next real prompt lifts the fence and its own tools show Running.
            hooks.run("prompt-submit", hooks.prompt)
            #expect(hooks.turnSettled == false)
            let afterPrompt = hooks.snapshot().count
            hooks.run("pre-tool-use", hooks.helperTool)
            #expect(hooks.lifecycle == "running")
            #expect(statusLine(Array(hooks.snapshot().dropFirst(afterPrompt)), value: "Running") != nil)
        }
    }

    @Test func pendingBackgroundWorkPreToolUseDoesNotRepublishRunning() throws {
        try withHookSession(name: "helper-after-pending-stop") { hooks in
            hooks.run("prompt-submit", hooks.prompt)
            hooks.run("stop", hooks.stop(pendingWork: true))
            // The fork keeps a pane with pending background work as Running.
            #expect(hooks.lifecycle == "running")
            #expect(hooks.turnSettled == true)
            let afterStop = hooks.snapshot().count

            hooks.run("pre-tool-use", hooks.helperTool)
            let afterTool = Array(hooks.snapshot().dropFirst(afterStop))
            #expect(hooks.lifecycle == "running")
            #expect(statusLine(afterTool, value: "Running") == nil,
                    "The helper tool must not touch the settled turn's status; saw \(afterTool)")
            #expect(afterTool.contains { $0.hasPrefix("clear_notifications ") } == false,
                    "The helper tool must not clear the turn's notifications; saw \(afterTool)")
        }
    }

    @Test func notificationAfterStopKeepsHelperToolFromReopeningTurn() throws {
        try withHookSession(name: "helper-after-stop-notification") { hooks in
            hooks.run("prompt-submit", hooks.prompt)
            hooks.run("stop", hooks.stop(pendingWork: false))
            hooks.run("notification", hooks.permissionPrompt)
            #expect(hooks.lifecycle == "needsInput")
            #expect(hooks.turnSettled == true, "A notification must not lift the settled-turn fence")
            let afterNotification = hooks.snapshot().count

            hooks.run("pre-tool-use", hooks.helperTool)
            let afterTool = Array(hooks.snapshot().dropFirst(afterNotification))
            #expect(hooks.lifecycle == "needsInput")
            #expect(statusLine(afterTool, value: "Running") == nil, "saw \(afterTool)")

            hooks.run("prompt-submit", hooks.prompt)
            let afterPrompt = hooks.snapshot().count
            hooks.run("pre-tool-use", hooks.helperTool)
            #expect(hooks.lifecycle == "running")
            #expect(hooks.turnSettled == false)
            #expect(statusLine(Array(hooks.snapshot().dropFirst(afterPrompt)), value: "Running") != nil)
        }
    }

    @Test(arguments: ["SessionStart", "Notification"])
    func toolUseWithoutCompletedTurnRemainsRunning(boundary: String) throws {
        try withHookSession(name: "tool-mid-turn-\(boundary.lowercased())") { hooks in
            hooks.run("prompt-submit", hooks.prompt)
            switch boundary {
            case "SessionStart":
                hooks.run("session-start", #"{"session_id":"\#(hooks.session)","hook_event_name":"SessionStart","source":"resume"}"#)
            default:
                hooks.run("notification", hooks.permissionPrompt)
            }
            #expect(hooks.turnSettled == false, "Only Stop settles a turn")
            let afterBoundary = hooks.snapshot().count

            hooks.run("pre-tool-use", hooks.helperTool)
            #expect(hooks.lifecycle == "running")
            #expect(statusLine(Array(hooks.snapshot().dropFirst(afterBoundary)), value: "Running") != nil,
                    "A tool inside an unfinished turn must still show Running")
        }
    }

    @Test func stopWithRunningBackgroundTaskTagsPendingAndCaches() throws {
        let session = "bg-running-session"
        let stdin = #"""
        {"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[{"id":"t1","type":"shell","status":"running","description":"build","command":"sleep 1"}],"session_crons":[]}
        """#
        let (snapshot, cached) = try runStopHook(name: "bg-run", sessionId: session, stdin: stdin)
        #expect(
            notifyLine(snapshot, containing: "c=turn-complete;p=1") != nil,
            "Stop with a running background task must tag the done-ping pending; saw \(snapshot)"
        )
        #expect(cached == true)
        // Sidebar pill must not say "Idle" while background work is live.
        #expect(statusLine(snapshot, value: "Running") != nil,
                "Pending stop must show a Running pill, not Idle; saw \(snapshot)")
        #expect(statusLine(snapshot, value: "Idle") == nil)
        // And the hibernation lifecycle must stay non-idle so the planner can't
        // SIGTERM the live background task.
        #expect(lifecycleLine(snapshot, value: "running") != nil,
                "Pending stop must publish a running lifecycle; saw \(snapshot)")
        #expect(lifecycleLine(snapshot, value: "idle") == nil)
    }

    @Test func stopWithEmptyArraysTagsIdleAndCachesFalse() throws {
        let session = "bg-empty-session"
        let stdin = #"""
        {"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[],"session_crons":[]}
        """#
        let (snapshot, cached) = try runStopHook(name: "bg-empty", sessionId: session, stdin: stdin)
        #expect(notifyLine(snapshot, containing: "c=turn-complete;p=0") != nil,
                "Truly-idle stop must tag pending=0; saw \(snapshot)")
        #expect(cached == false)
        // Truly-idle turn end keeps the "Idle" pill and the hibernatable lifecycle.
        #expect(statusLine(snapshot, value: "Idle") != nil,
                "Truly-idle stop must show the Idle pill; saw \(snapshot)")
        #expect(lifecycleLine(snapshot, value: "idle") != nil,
                "Truly-idle stop must publish an idle lifecycle; saw \(snapshot)")
    }

    @Test func stopWithPendingCronTagsPending() throws {
        let session = "bg-cron-session"
        let stdin = #"""
        {"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[],"session_crons":[{"id":"c1"}]}
        """#
        let (snapshot, _) = try runStopHook(name: "bg-cron", sessionId: session, stdin: stdin)
        #expect(notifyLine(snapshot, containing: "c=turn-complete;p=1") != nil,
                "A pending scheduled wakeup must tag pending=1; saw \(snapshot)")
    }

    @Test func stopWithoutBackgroundKeysOldClientTagsNotPending() throws {
        // claude < 2.1.145 omits both arrays entirely: preserve prior behavior.
        let session = "bg-oldclient-session"
        let stdin = #"""
        {"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok"}
        """#
        let (snapshot, cached) = try runStopHook(name: "bg-old", sessionId: session, stdin: stdin)
        #expect(notifyLine(snapshot, containing: "c=turn-complete;p=0") != nil,
                "Absent arrays (old client) must behave as not-pending; saw \(snapshot)")
        #expect(cached == false)
    }

    @Test func notificationPermissionPromptTagsNeedsPermission() throws {
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "notif-perm")
        defer { context.cleanup() }
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-notif-perm",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-notif-perm",
            storeURL: context.root.appendingPathComponent("claude-hook-sessions.json")
        )
        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"notif-perm-session","cwd":"/tmp/x","hook_event_name":"Notification","message":"Claude needs your permission","notification_type":"permission_prompt"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)
        let snapshot = context.state.snapshot()
        #expect(notifyLine(snapshot, containing: "c=needs-permission;p=0") != nil,
                "permission_prompt must tag needs-permission; saw \(snapshot)")
        // Suppressing the idle nag must not over-suppress: a permission prompt
        // really is blocked on the user, so both the lifecycle and the pill flip.
        #expect(lifecycleLine(snapshot, value: "needsInput") != nil,
                "permission_prompt must publish a needsInput lifecycle; saw \(snapshot)")
        #expect(statusLine(snapshot, value: "Needs input") != nil,
                "permission_prompt must set the Needs input pill; saw \(snapshot)")
    }

    @Test func notificationWithoutTypeFallsBackToCueClassification() throws {
        // Older claude clients omit notification_type; the permission cue in the
        // message must still gate the alert under "Agent Needs Permission".
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "notif-cue")
        defer { context.cleanup() }
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-notif-cue",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-notif-cue",
            storeURL: context.root.appendingPathComponent("claude-hook-sessions.json")
        )
        let result = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"notif-cue-session","cwd":"/tmp/x","hook_event_name":"Notification","message":"Claude needs your permission to run a tool"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(result)
        #expect(notifyLine(context.state.snapshot(), containing: "c=needs-permission;p=0") != nil,
                "Permission-cue notification without notification_type must tag needs-permission; saw \(context.state.snapshot())")
    }

    @Test func idlePromptAfterPendingStopReadsCachedPending() throws {
        // Stop (pending) then idle_prompt on the SAME session: the idle nag must
        // inherit the cached pending flag because its payload lacks background_tasks.
        let session = "idle-after-pending"
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "idle-pending")
        defer { context.cleanup() }
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-idle-pending",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-idle-pending",
            storeURL: storeURL
        )
        let stopResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[{"id":"t1","type":"shell","status":"running","description":"build","command":"sleep 1"}],"session_crons":[]}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(stopResult)

        let notifResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(notifResult)
        let snapshot = context.state.snapshot()
        #expect(notifyLine(snapshot, containing: "c=idle-reminder;p=1") != nil,
                "idle_prompt after a pending stop must inherit pending=1; saw \(snapshot)")
        // A pending idle reminder must not flip the pane to "Needs input": the
        // banner is suppressed app-side and the pane is still Running.
        #expect(statusLine(snapshot, value: "Needs input") == nil,
                "Pending idle_prompt must not set a Needs input pill; saw \(snapshot)")
    }

    @Test func idlePromptAfterIdleStopTagsNotPending() throws {
        let session = "idle-after-idle"
        let harness = ClaudeHookSurfaceResolutionSwiftTests()
        let context = try harness.makeClaudeHookContext(name: "idle-idle")
        defer { context.cleanup() }
        let storeURL = context.root.appendingPathComponent("claude-hook-sessions.json")
        let handled = harness.startClaudeSurfaceResolutionServer(
            context: context,
            surfaces: [(context.surfaceId, "surface:1", true)],
            ttyName: "ttys-idle-idle",
            ttySurfaceId: context.surfaceId
        )
        let environment = harness.claudeHookEnvironment(
            context: context,
            surfaceId: context.surfaceId,
            ttyName: "ttys-idle-idle",
            storeURL: storeURL
        )
        let stopResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "stop"],
            environment: environment,
            standardInput: #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Stop","last_assistant_message":"ok","background_tasks":[],"session_crons":[]}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(stopResult)
        let notifResult = harness.runProcess(
            executablePath: context.cliPath,
            arguments: ["hooks", "claude", "notification"],
            environment: environment,
            standardInput: #"{"session_id":"\#(session)","cwd":"/tmp/x","hook_event_name":"Notification","message":"Claude is waiting for your input","notification_type":"idle_prompt"}"#,
            timeout: 5
        )
        #expect(handled.wait(timeout: .now() + 5) == .success)
        harness.assertSuccessfulHook(notifResult)
        let snapshot = context.state.snapshot()
        #expect(notifyLine(snapshot, containing: "c=idle-reminder;p=0") != nil,
                "idle_prompt after an idle stop must tag pending=0; saw \(snapshot)")
        // The idle nag is never a blocked-on-user state: the pane is idle by
        // definition when it fires, and nothing but a later hook would ever
        // clear a "Needs input" flip, so the pill would lie forever and the
        // non-idle lifecycle would block hibernation. The banner still goes out.
        #expect(statusLine(snapshot, value: "Needs input") == nil,
                "Idle idle_prompt must not set the Needs input pill; saw \(snapshot)")
        #expect(lifecycleLine(snapshot, value: "needsInput") == nil,
                "Idle idle_prompt must not publish a needsInput lifecycle; saw \(snapshot)")
        #expect(storedLifecycle(storeURL, sessionId: session) == "idle",
                "Idle idle_prompt must leave the stored lifecycle at idle; saw \(String(describing: storedLifecycle(storeURL, sessionId: session)))")
    }
}
