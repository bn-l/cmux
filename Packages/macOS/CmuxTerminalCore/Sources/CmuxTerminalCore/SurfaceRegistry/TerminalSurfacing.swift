public import Foundation

/// Read-only cross-domain view of a registered terminal surface.
///
/// Implemented by the app's terminal surface model so the engine's surface
/// registry can track identity without importing the model layer. `id` is
/// immutable for the surface's lifetime, so it is safe to read from any
/// thread.
public protocol TerminalSurfacing: AnyObject {
    /// The stable identity of the terminal surface.
    var id: UUID { get }
}
