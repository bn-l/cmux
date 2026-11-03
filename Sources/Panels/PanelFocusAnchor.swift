import AppKit
import SwiftUI

/// A zero-size first-responder target placed behind a SwiftUI panel (custom
/// sidebar panes), so `focus()` has an AppKit view to make first responder and
/// `ownedFocusIntent` can tell whether a responder sits inside the panel.
struct PanelFocusAnchor: NSViewRepresentable {
    final class Coordinator {
        var onViewChange: (PanelFocusAnchorView?) -> Void
        weak var attachedView: PanelFocusAnchorView?

        init(onViewChange: @escaping (PanelFocusAnchorView?) -> Void) {
            self.onViewChange = onViewChange
        }

        func attach(_ view: PanelFocusAnchorView) {
            guard attachedView !== view else { return }
            attachedView = view
            onViewChange(view)
        }

        func detach(_ view: PanelFocusAnchorView) {
            guard attachedView === view else { return }
            attachedView = nil
            onViewChange(nil)
        }
    }

    let onViewChange: (PanelFocusAnchorView?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onViewChange: onViewChange)
    }

    func makeNSView(context: Context) -> PanelFocusAnchorView {
        let view = PanelFocusAnchorView()
        context.coordinator.attach(view)
        return view
    }

    func updateNSView(_ nsView: PanelFocusAnchorView, context: Context) {
        context.coordinator.onViewChange = onViewChange
        context.coordinator.attach(nsView)
    }

    static func dismantleNSView(_ nsView: PanelFocusAnchorView, coordinator: Coordinator) {
        coordinator.detach(nsView)
    }
}

final class PanelFocusAnchorView: NSView {
    override var acceptsFirstResponder: Bool { true }

    func ownsKeyboardFocus(_ responder: NSResponder) -> Bool {
        if responder === self { return true }
        guard let responderView = Self.view(for: responder) else { return false }
        guard let root = focusRootView else { return false }
        return responderView === root || responderView.isDescendant(of: root)
    }

    private static func view(for responder: NSResponder) -> NSView? {
        if let view = responder as? NSView {
            return view
        }
        if let textView = responder as? NSTextView,
           let delegateView = textView.delegate as? NSView {
            return delegateView
        }
        return nil
    }

    private var focusRootView: NSView? {
        guard let superview else { return nil }
        var current: NSView? = superview
        while let view = current {
            let typeName = String(describing: type(of: view))
            if typeName.contains("NSHosting") || typeName.contains("ViewHost") {
                return view
            }
            current = view.superview
        }
        return superview
    }
}
