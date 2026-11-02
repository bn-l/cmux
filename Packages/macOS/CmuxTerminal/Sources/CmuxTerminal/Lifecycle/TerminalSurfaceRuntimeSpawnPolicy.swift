/// How a terminal surface should enter its native Ghostty runtime.
public enum TerminalSurfaceRuntimeSpawnPolicy: Sendable {
    /// Create the native runtime surface as soon as the view is ready.
    case immediate

    /// Pace creation through the session-restore queue to avoid a login-shell stampede.
    case pacedSessionRestore

    /// Pace like ``pacedSessionRestore`` for a terminal whose first spawn runs
    /// a restored agent resume command. An agent costs far more to start than
    /// a login shell, so the queue holds a longer cooldown after this spawn.
    case pacedAgentResumeRestore

    /// Whether creation goes through the session-restore queue.
    var pacesSessionRestore: Bool {
        switch self {
        case .immediate: false
        case .pacedSessionRestore, .pacedAgentResumeRestore: true
        }
    }
}
