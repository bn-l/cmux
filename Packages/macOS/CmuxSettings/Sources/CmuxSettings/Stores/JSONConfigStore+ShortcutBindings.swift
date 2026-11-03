import Foundation

/// Keyboard shortcut bindings, read and written the way the app applies them
/// (see ``ShortcutConfigBindings``).
///
/// A plain read of `shortcuts.bindings` would miss bindings written directly
/// in `shortcuts`, which the app applies over `bindings`, and a write there
/// would be overridden by them. Writes touch only the edited entry, so the
/// other hand-written bindings keep their form, invalid ones included.
extension JSONConfigStore {
    /// The binding cmux applies for each action the file binds, by action id.
    /// Actions that are absent, or whose binding is invalid, are left out.
    public func shortcutBindings() -> [String: StoredShortcut] {
        ShortcutConfigBindings.bindings(
            inShortcutsSection: ShortcutConfigBindings.sectionPath.lookup(in: loadedRoot()) as? [String: Any] ?? [:]
        )
    }

    /// ``shortcutBindings()`` now and after every file change that alters it.
    public nonisolated func shortcutBindingValues() -> AsyncStream<[String: StoredShortcut]> {
        values { await $0.shortcutBindings() }
    }

    /// Writes `shortcut` as `action`'s binding, at the entry the app applies:
    /// `shortcuts.<actionId>` when the file has one, otherwise
    /// `shortcuts.bindings.<actionId>`. Creates the file when missing.
    ///
    /// - Throws: Errors from `FileManager` or `JSONSerialization` writing the file.
    public func setShortcutBinding(_ shortcut: StoredShortcut, for action: ShortcutAction) throws {
        try mutateRoot { ShortcutConfigBindings.assign(shortcut, for: action, in: &$0) }
    }

    /// Removes every action's binding, in `shortcuts.bindings` and directly in
    /// `shortcuts`, so every action is back on its default.
    ///
    /// - Throws: Errors from `FileManager` or `JSONSerialization` writing the file.
    public func resetShortcutBindings() throws {
        try mutateRoot { ShortcutConfigBindings.removeAll(in: &$0) }
    }
}
