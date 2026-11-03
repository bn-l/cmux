import Foundation

/// A bounded count snapshot of the terminal surface registry.
public struct TerminalSurfaceRegistryDiagnosticSnapshot: Equatable, Sendable {
    /// The number of live surface model objects still registered.
    public let registeredSurfaceCount: Int

    /// The number of native runtime surface pointers still owned by registered surfaces.
    public let runtimeSurfaceCount: Int

    /// Creates a diagnostic snapshot.
    ///
    /// - Parameters:
    ///   - registeredSurfaceCount: The number of live surface model objects.
    ///   - runtimeSurfaceCount: The number of native runtime surface pointers.
    public init(
        registeredSurfaceCount: Int,
        runtimeSurfaceCount: Int
    ) {
        self.registeredSurfaceCount = registeredSurfaceCount
        self.runtimeSurfaceCount = runtimeSurfaceCount
    }

    /// Returns the JSON-compatible representation used by diagnostics and telemetry.
    public func payload() -> [String: Any] {
        [
            "registered_surface_count": registeredSurfaceCount,
            "runtime_surface_count": runtimeSurfaceCount
        ]
    }
}
