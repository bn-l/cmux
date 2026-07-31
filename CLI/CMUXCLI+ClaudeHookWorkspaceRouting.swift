// Claude hook workspace routing resolution: route to the originating workspace, never the focused tab.

import Foundation

extension CMUXCLI {
    /// Resolve the workspace a Claude hook should mutate, in strict priority order:
    /// the caller's own live binding (only when `preferCallerBindingOverRecord`, i.e.
    /// the hook carried no explicit `--workspace`/`--surface`), the recorded/preferred
    /// workspace, the live `CMUX_WORKSPACE_ID` fallback, then the caller binding again.
    /// Each candidate is validated against a live workspace before it is accepted.
    ///
    /// The caller binding outranks the recorded workspace because the record is only
    /// ever as good as the routing that wrote it. One SessionStart resolved through a
    /// recycled `ttysNNN` name (the tty table is re-seeded from the previous run's
    /// snapshot at restore) writes the wrong pane, and every later hook for that
    /// session — status pill, notification, `clear_notifications`, resume binding —
    /// then follows the poisoned record and re-persists it, so the mis-routing grows
    /// with each restart. Preferring the live binding lets a single hook heal the
    /// record instead (the upsert paths rewrite `workspaceId`/`surfaceId`).
    ///
    /// Returns `nil` when the caller cannot be positively identified. It deliberately
    /// does NOT fall back to `workspace.current` (the focused tab): routing a
    /// background agent's status/notification/summary to whatever tab happens to be
    /// focused mis-delivers it onto an unrelated session (this mirrors the generic
    /// agent hook, which already no-ops instead of guessing). Callers treat `nil` as a
    /// no-op rather than mutating an arbitrary workspace.
    func resolvePreferredWorkspaceIdForClaudeHook(
        preferred: String?,
        fallback: String?,
        preferCallerBindingOverRecord: Bool = false,
        callerTerminalBinding: (() -> CallerTerminalBinding?)? = nil,
        client: SocketClient
    ) throws -> String? {
        if preferCallerBindingOverRecord,
           let callerWorkspaceId = uniqueCallerWorkspaceIdForClaudeHook(
               callerTerminalBinding: callerTerminalBinding,
               client: client
           ) {
            return callerWorkspaceId
        }
        if let preferred = nonEmptyClaudeHookIdentifier(preferred),
           let resolved = strictClaudeHookWorkspaceId(preferred, client: client) {
            return resolved
        }
        if let fallback = nonEmptyClaudeHookIdentifier(fallback),
           let resolved = strictClaudeHookWorkspaceId(fallback, client: client) {
            return resolved
        }
        return uniqueCallerWorkspaceIdForClaudeHook(
            callerTerminalBinding: callerTerminalBinding,
            client: client
        )
    }

    /// The workspace that CURRENTLY hosts `surfaceId`, or `nil` when no live workspace
    /// lists it. Panel ids survive a restart but workspace ids are minted fresh on every
    /// launch, and a tab can be dragged between workspaces mid-session, so the hook
    /// process's ambient `CMUX_WORKSPACE_ID` is not a trustworthy pairing for its
    /// ambient `CMUX_SURFACE_ID`. Checking the env workspace first keeps the common
    /// case at a single `surface.list`; the scan only runs when the pairing is wrong.
    func claudeHookWorkspaceHostingSurface(
        _ surfaceId: String,
        preferredWorkspaceId: String?,
        client: SocketClient
    ) -> String? {
        if let preferredWorkspaceId = nonEmptyClaudeHookIdentifier(preferredWorkspaceId),
           isUUID(preferredWorkspaceId),
           claudeHookSurfaceIsListed(surfaceId, workspaceId: preferredWorkspaceId, client: client) {
            return preferredWorkspaceId
        }
        guard let windows = try? client.sendV2(method: "window.list") else { return nil }
        for window in windows["windows"] as? [[String: Any]] ?? [] {
            guard let windowId = normalizedHandleValue(window["id"] as? String),
                  let listed = try? client.sendV2(
                      method: "workspace.list",
                      params: ["window_id": windowId]
                  ) else {
                continue
            }
            for item in listed["workspaces"] as? [[String: Any]] ?? [] {
                guard let workspaceId = normalizedHandleValue(item["id"] as? String),
                      claudeHookSurfaceIsListed(surfaceId, workspaceId: workspaceId, client: client) else {
                    continue
                }
                return workspaceId
            }
        }
        return nil
    }

    /// The pane named by the hook process's own `CMUX_SURFACE_ID`, paired with the
    /// workspace that hosts that pane right now rather than with `CMUX_WORKSPACE_ID`.
    func claudeHookEnvironmentSurfaceBinding(
        surfaceId: String?,
        workspaceId: String?,
        client: SocketClient
    ) -> CallerTerminalBinding? {
        guard let surfaceId = nonEmptyClaudeHookIdentifier(surfaceId),
              isUUID(surfaceId),
              let hostWorkspaceId = claudeHookWorkspaceHostingSurface(
                  surfaceId,
                  preferredWorkspaceId: workspaceId,
                  client: client
              ) else {
            return nil
        }
        return CallerTerminalBinding(workspaceId: hostWorkspaceId, surfaceId: surfaceId)
    }

    /// Which pane the hook's agent actually runs in, in the authority order the routing
    /// fix is built on:
    ///
    /// 1. the agent process's location in the live process tree (`system.top`) — ground
    ///    truth, since a pid lives in exactly one surface;
    /// 2. the ambient `CMUX_SURFACE_ID`, resolved to its current host workspace;
    /// 3. the caller's tty, and only when it maps to exactly one live pane.
    ///
    /// The process walk is the expensive step (it enumerates every window's process
    /// tree) and hooks like PreToolUse fire on every tool call, so it is skipped when
    /// the two cheap candidates already agree — the only way they can both be wrong is
    /// if the tty table and the shell's own env were poisoned identically, which cannot
    /// happen. Disagreement (a recycled tty name, or a `CMUX_SURFACE_ID` leaked into a
    /// sibling pane's launcher) is exactly the case that must pay for the process walk.
    func resolveClaudeHookCallerBinding(
        env: [String: String],
        includeAmbientTTY: Bool,
        agentPIDs: [Int],
        client: SocketClient,
        processTerminalBinding: (Int) -> CallerTerminalBinding?
    ) -> CallerTerminalBinding? {
        func listed(_ binding: CallerTerminalBinding?) -> CallerTerminalBinding? {
            guard let binding,
                  claudeHookSurfaceIsListed(
                      binding.surfaceId,
                      workspaceId: binding.workspaceId,
                      client: client
                  ) else {
                return nil
            }
            return binding
        }

        let ttyBinding = listed(uniqueCallerTerminalBindingByTTY(
            client: client,
            includeAmbientTTY: includeAmbientTTY
        ))
        let envBinding = listed(claudeHookEnvironmentSurfaceBinding(
            surfaceId: env["CMUX_SURFACE_ID"],
            workspaceId: env["CMUX_WORKSPACE_ID"],
            client: client
        ))
        if let ttyBinding,
           let envBinding,
           ttyBinding.workspaceId == envBinding.workspaceId,
           ttyBinding.surfaceId == envBinding.surfaceId {
            return ttyBinding
        }
        for pid in agentPIDs {
            if let processBinding = listed(processTerminalBinding(pid)) {
                return processBinding
            }
        }
        return envBinding ?? ttyBinding
    }

    /// Resolve `raw` to a workspace id only when that workspace currently exists.
    func strictClaudeHookWorkspaceId(_ raw: String, client: SocketClient) -> String? {
        // UUID identities (hook session records, live CMUX_WORKSPACE_ID) validate directly.
        if isUUID(raw) {
            return claudeHookWorkspaceExists(raw, client: client) ? raw : nil
        }
        // Explicit non-UUID selectors (handle refs like "workspace:1", numeric indexes —
        // both documented for --workspace) resolve strictly. `resolveWorkspaceId` fails
        // closed for every non-blank selector, and `raw` is non-blank here (callers pass
        // it through `nonEmptyClaudeHookIdentifier`), so the focused-tab fallback inside
        // `resolveWorkspaceId` is structurally unreachable and the "never fall back to
        // focused" invariant holds.
        guard let resolved = try? resolveWorkspaceId(raw, client: client),
              isUUID(resolved),
              claudeHookWorkspaceExists(resolved, client: client) else {
            return nil
        }
        return resolved
    }

    func claudeHookWorkspaceExists(_ workspaceId: String, client: SocketClient) -> Bool {
        (try? client.sendV2(method: "surface.list", params: ["workspace_id": workspaceId])) != nil
    }

    /// Caller-TTY binding that refuses ambiguous TTY matches: returns a binding only
    /// when every `debug.terminals` entry for the caller's TTY name agrees on a single
    /// workspace and surface (macOS reuses `ttysNNN` names, and stale entries can
    /// shadow live ones).
    /// PID-derived bindings don't need this guard — a PID lives in exactly one surface.
    func uniqueCallerTerminalBindingByTTY(
        client: SocketClient,
        includeAmbientTTY: Bool = true
    ) -> CallerTerminalBinding? {
        guard let ttyName = resolveCallerTTYName(includeAmbientTTY: includeAmbientTTY),
              let payload = try? client.sendV2(method: "debug.terminals") else {
            return nil
        }
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        var matched: [CallerTerminalBinding] = []
        for terminal in terminals {
            guard normalizedTTYName(terminal["tty"] as? String) == ttyName,
                  let workspaceId = normalizedHandleValue(terminal["workspace_id"] as? String),
                  let surfaceId = normalizedHandleValue(terminal["surface_id"] as? String) else {
                continue
            }
            matched.append(CallerTerminalBinding(workspaceId: workspaceId, surfaceId: surfaceId))
        }
        guard let first = matched.first,
              matched.allSatisfy({ $0.workspaceId == first.workspaceId && $0.surfaceId == first.surfaceId }) else {
            return nil
        }
        return first
    }

    /// Like `resolveCallerWorkspaceIdForClaudeHook`, but refuses to guess when the
    /// caller's TTY name maps to more than one workspace. macOS reuses `ttysNNN`
    /// device names across panes/sessions, so a first-match on a shared name would
    /// route to an arbitrary sibling session. The provider closure yields only
    /// unambiguous-TTY or PID-derived bindings, so it is trusted directly.
    func uniqueCallerWorkspaceIdForClaudeHook(
        callerTerminalBinding: (() -> CallerTerminalBinding?)?,
        client: SocketClient
    ) -> String? {
        if let callerTerminalBinding {
            guard let binding = callerTerminalBinding(),
                  claudeHookSurfaceIsListed(binding.surfaceId, workspaceId: binding.workspaceId, client: client) else {
                return nil
            }
            return binding.workspaceId
        }
        guard let ttyName = resolveCallerTTYName(),
              let payload = try? client.sendV2(method: "debug.terminals") else {
            return nil
        }
        let terminals = payload["terminals"] as? [[String: Any]] ?? []
        var matchedWorkspaces: Set<String> = []
        for terminal in terminals {
            guard normalizedTTYName(terminal["tty"] as? String) == ttyName,
                  let workspaceId = normalizedHandleValue(terminal["workspace_id"] as? String) else {
                continue
            }
            matchedWorkspaces.insert(workspaceId)
        }
        guard matchedWorkspaces.count == 1,
              let only = matchedWorkspaces.first,
              claudeHookWorkspaceExists(only, client: client) else {
            return nil
        }
        return only
    }

    func nonEmptyClaudeHookIdentifier(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }
}
