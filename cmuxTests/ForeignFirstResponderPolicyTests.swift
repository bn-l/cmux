import AppKit
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Coverage for ``shouldRespectForeignFirstResponder(_:in:)`` — the policy that
/// decides whether an active terminal yields to the window's current first responder or reclaims
/// focus. Regression coverage for issue #5269 (a stranded responder must not block focus).
@MainActor
@Suite struct ForeignFirstResponderPolicyTests {
    private func makeWindow() -> NSWindow {
        NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
    }

    @Test func respectsInWindowTextEditor() {
        let window = makeWindow()
        let textView = NSTextView(frame: .zero)
        window.contentView?.addSubview(textView)
        #expect(shouldRespectForeignFirstResponder(textView, in: window))
    }

    /// The #5269 regression: a text responder stranded in another window must NOT be respected, so
    /// the terminal can reclaim focus. Without the window-membership check this returns `true`.
    @Test func reclaimsFromStrandedTextEditorInAnotherWindow() {
        let windowA = makeWindow()
        let windowB = makeWindow()
        let textView = NSTextView(frame: .zero)
        windowB.contentView?.addSubview(textView) // belongs to windowB, not windowA
        #expect(!shouldRespectForeignFirstResponder(textView, in: windowA))
    }

    @Test func reclaimsFromDetachedResponder() {
        let window = makeWindow()
        let textView = NSTextView(frame: .zero) // never added to a window -> .window is nil
        #expect(!shouldRespectForeignFirstResponder(textView, in: window))
    }

    @Test func doesNotRespectPlainInWindowView() {
        let window = makeWindow()
        let view = NSView(frame: .zero)
        window.contentView?.addSubview(view)
        // Not a text editor: the terminal reclaims focus.
        #expect(!shouldRespectForeignFirstResponder(view, in: window))
    }
}
