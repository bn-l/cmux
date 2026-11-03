import Foundation

/// The catalog of well-known keyboard-shortcut context keys a ``ShortcutWhenClause``
/// can reference, modeled on VS Code's `when`-clause context keys.
///
/// This enum is the single source of truth for the documented key vocabulary: its
/// raw values are the exact names usable in `shortcuts.when` predicates, and the
/// app target references these cases when populating a ``ShortcutContext`` at key
/// dispatch (so key names never drift between declaration and runtime).
///
/// Unknown keys are still permitted in a clause — ``ShortcutWhenClause/parse(_:)``
/// accepts any bareword and an absent key evaluates to `false`, matching VS Code.
/// This catalog is what tooling (docs, autocomplete) advertises as supported.
///
/// The focus keys (``browserFocus``, ``markdownFocus``,
/// ``filePreviewTextEditorFocus``, ``terminalFocus``) are also expressed as ``ShortcutFocusAtom`` cases; a clause
/// referencing one of those names parses to ``ShortcutWhenClause/atom(_:)`` rather
/// than ``ShortcutWhenClause/key(_:)`` so existing focus behavior is preserved.
public enum ShortcutContextKnownKey: String, CaseIterable, Sendable {
    /// A browser panel owns focus.
    case browserFocus
    /// A markdown preview viewer owns focus.
    case markdownFocus
    /// A file-preview text editor owns focus.
    case filePreviewTextEditorFocus
    /// A terminal owns focus (no other focus atom holds).
    case terminalFocus
    /// The command palette overlay is visible in the shortcut's window.
    case commandPaletteVisible
    /// The focused terminal's find overlay is open.
    case terminalFindVisible
    /// The focused workspace is using the freeform canvas layout.
    case workspaceCanvasLayout
    /// The number of panes in the focused workspace.
    case paneCount
    /// The number of open workspaces in the focused window.
    case workspaceCount

    /// The static value kind this key carries.
    public var valueType: ShortcutContextValueType {
        switch self {
        case .browserFocus, .markdownFocus, .filePreviewTextEditorFocus, .terminalFocus,
             .commandPaletteVisible, .terminalFindVisible, .workspaceCanvasLayout:
            return .bool
        case .paneCount, .workspaceCount:
            return .int
        }
    }
}
