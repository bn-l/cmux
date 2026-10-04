import AppKit
import CmuxFoundation
import ObjectiveC
import Observation
import os
import SwiftUI

private var workspaceNameFlashOverlayKey: UInt8 = 0

/// One showing of the workspace-name flash.
struct WorkspaceNameFlash: Equatable {
    let title: String
    /// The workspace's color as normalized hex, or `nil` when it has none.
    let colorHex: String?
    /// Distinguishes back-to-back flashes, so jumping between two workspaces
    /// restarts the animation every time.
    let id = UUID()
}

@MainActor
@Observable
final class WorkspaceNameFlashModel {
    var flash: WorkspaceNameFlash?
}

/// Shows a workspace's name in large type over a window for about a second.
/// The attention jump uses it when it lands in a different workspace, so rapid
/// switching between agents never leaves you unsure which project you are in.
@MainActor
final class WorkspaceNameFlashOverlayController {
    private static let logger = Logger(subsystem: "com.cmuxterm.app", category: "WorkspaceNameFlash")
    static let visibleDuration: Duration = .milliseconds(1100)
    static let fadeDuration: Duration = .milliseconds(200)

    private weak var window: NSWindow?
    private let containerView = PassthroughWindowOverlayContainerView(frame: .zero)
    private let model = WorkspaceNameFlashModel()
    private let chromeComposition = AppWindowChromeComposition()
    private var installConstraints: [NSLayoutConstraint] = []
    private var hideTask: Task<Void, Never>?

    /// The flash on screen, if any.
    var currentFlash: WorkspaceNameFlash? { model.flash }

    static func controller(for window: NSWindow) -> WorkspaceNameFlashOverlayController {
        if let existing = existingController(for: window) { return existing }
        let controller = WorkspaceNameFlashOverlayController(window: window)
        objc_setAssociatedObject(window, &workspaceNameFlashOverlayKey, controller, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        return controller
    }

    static func existingController(for window: NSWindow) -> WorkspaceNameFlashOverlayController? {
        objc_getAssociatedObject(window, &workspaceNameFlashOverlayKey) as? WorkspaceNameFlashOverlayController
    }

    private init(window: NSWindow) {
        self.window = window
        let hostingView = NSHostingView(rootView: WorkspaceNameFlashView(model: model).cmuxFontMagnificationEnvironment())
        hostingView.translatesAutoresizingMaskIntoConstraints = false
        containerView.translatesAutoresizingMaskIntoConstraints = false
        containerView.isHidden = true
        containerView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: containerView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
        ])
    }

    /// Shows `title` (with the workspace color as an accent when present),
    /// replacing any flash already on screen, and fades it out afterwards.
    func show(title: String, colorHex: String?) {
        hideTask?.cancel()
        if installOnTop() {
            containerView.isHidden = false
        } else {
            Self.logger.error("no overlay target in the window; the workspace name flash is not visible")
        }
        withAnimation(.easeOut(duration: 0.15)) {
            model.flash = WorkspaceNameFlash(title: title, colorHex: colorHex)
        }
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: title, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
        hideTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: Self.visibleDuration)
                withAnimation(.easeIn(duration: 0.2)) { self?.model.flash = nil }
                try await Task.sleep(for: Self.fadeDuration)
                self?.containerView.isHidden = true
            } catch {
                // Cancelled by a newer flash, which owns the overlay now.
            }
        }
    }

    /// Installs the overlay above everything in the window's content, terminal
    /// portals included. Re-adding it on every show keeps it on top after a
    /// workspace switch reorders the portal views.
    private func installOnTop() -> Bool {
        guard let window,
              let target = chromeComposition.contentOverlayTargetResolver.installationTarget(for: window) else {
            return false
        }
        NSLayoutConstraint.deactivate(installConstraints)
        target.container.addSubview(containerView, positioned: .above, relativeTo: nil)
        installConstraints = [
            containerView.topAnchor.constraint(equalTo: target.reference.topAnchor),
            containerView.bottomAnchor.constraint(equalTo: target.reference.bottomAnchor),
            containerView.leadingAnchor.constraint(equalTo: target.reference.leadingAnchor),
            containerView.trailingAnchor.constraint(equalTo: target.reference.trailingAnchor),
        ]
        NSLayoutConstraint.activate(installConstraints)
        return true
    }
}

private struct WorkspaceNameFlashView: View {
    let model: WorkspaceNameFlashModel

    var body: some View {
        ZStack {
            if let flash = model.flash {
                WorkspaceNameFlashBadge(flash: flash)
                    .id(flash.id)
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .allowsHitTesting(false)
    }
}

private struct WorkspaceNameFlashBadge: View {
    let flash: WorkspaceNameFlash

    var body: some View {
        // The badge is always dark, so use the color as the sidebar draws it on dark.
        let accent = flash.colorHex
            .flatMap { WorkspaceTabColorSettings.displayNSColor(hex: $0, colorScheme: .dark) }
            .map { Color(nsColor: $0) }
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        HStack(spacing: 14) {
            if let accent {
                Image(systemName: "circle.fill")
                    .cmuxFont(size: 24)
                    .foregroundStyle(accent)
            }
            Text(flash.title)
                .cmuxFont(size: 34, weight: .bold)
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 30)
        .padding(.vertical, 18)
        .background(shape.fill(Color.black.opacity(0.8)))
        .overlay(shape.strokeBorder(accent ?? Color.white.opacity(0.2), lineWidth: accent == nil ? 1 : 3))
        .shadow(color: .black.opacity(0.35), radius: 24, y: 8)
        .padding(48)
    }
}
