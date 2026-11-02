import AppKit
import CmuxTerminal
import CoreGraphics
import Testing
import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// The stale-scale predicate behind the screen-change repair (upstream #18163).
@MainActor
@Suite
struct GhosttyExternalDisplayScalingTests {
    @Test("screen changes reconcile a stale terminal backing scale")
    func screenChangeReconcilesStaleBackingScale() {
        #expect(GhosttyNSView.shouldReconcileBackingScale(currentScale: 2, targetScale: 1))
        #expect(GhosttyNSView.shouldReconcileBackingScale(currentScale: 1, targetScale: 2))
    }

    @Test("screen changes do not re-commit an already matching scale")
    func screenChangeSkipsMatchingBackingScale() {
        #expect(!GhosttyNSView.shouldReconcileBackingScale(currentScale: 2, targetScale: 2))
        #expect(!GhosttyNSView.shouldReconcileBackingScale(currentScale: 2, targetScale: 2.00001))
    }

    @Test("unknown or invalid scales never trigger a commit")
    func invalidScalesAreIgnored() {
        #expect(!GhosttyNSView.shouldReconcileBackingScale(currentScale: nil, targetScale: 2))
        #expect(!GhosttyNSView.shouldReconcileBackingScale(currentScale: 0, targetScale: 2))
        #expect(!GhosttyNSView.shouldReconcileBackingScale(currentScale: .nan, targetScale: 2))
        #expect(!GhosttyNSView.shouldReconcileBackingScale(currentScale: 2, targetScale: .infinity))
    }
}

/// End to end: a live terminal whose window moved to a display with another
/// backing scale, without AppKit delivering `viewDidChangeBackingProperties`,
/// is repaired by the window's screen-change notification.
@MainActor
final class GhosttyExternalDisplayScaleReconcileTests: XCTestCase {
    /// Stands in for a window AppKit moved to another display: the backing
    /// scale changes while no backing-properties callback reaches the views.
    private final class DisplayMoveWindow: NSWindow {
        var movedBackingScaleFactor: CGFloat?

        override var backingScaleFactor: CGFloat {
            movedBackingScaleFactor ?? super.backingScaleFactor
        }
    }

    private func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }

    /// Waits until `forceRefresh` has not run for `quietFor` seconds.
    private func waitForForceRefreshQuiet(
        _ surface: TerminalSurface,
        quietFor: TimeInterval,
        timeout: TimeInterval
    ) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        var lastCount = surface.debugForceRefreshCount()
        var lastChange = ProcessInfo.processInfo.systemUptime
        while ProcessInfo.processInfo.systemUptime < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            let count = surface.debugForceRefreshCount()
            let now = ProcessInfo.processInfo.systemUptime
            if count != lastCount {
                lastCount = count
                lastChange = now
            } else if now - lastChange >= quietFor {
                return true
            }
        }
        return false
    }

    private func makeHostedTerminal() -> (DisplayMoveWindow, TerminalSurface) {
        let window = DisplayMoveWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 320),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        let contentView = NSView(frame: window.contentRect(forFrameRect: window.frame))
        window.contentView = contentView

        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil
        )
        let hostedView = surface.hostedView
        hostedView.frame = contentView.bounds
        hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(hostedView)
        window.orderFront(nil)
        contentView.layoutSubtreeIfNeeded()
        hostedView.layoutSubtreeIfNeeded()
        return (window, surface)
    }

    func testScreenChangeRepairsRuntimeScaleAfterAMoveWithoutBackingCallback() {
        // Arrange: a live terminal at the window's original backing scale.
        let (window, surface) = makeHostedTerminal()
        defer {
            surface.releaseSurfaceForTesting()
            window.orderOut(nil)
            window.close()
        }
        let originalScale = max(1.0, window.backingScaleFactor)
        XCTAssertTrue(
            waitUntil(timeout: 5) { surface.surface != nil && surface.appliedContentScale == originalScale },
            "Precondition: the attached runtime should apply the window's backing scale \(originalScale); " +
                "surface=\(surface.surface != nil) applied=\(String(describing: surface.appliedContentScale))"
        )
        XCTAssertNotNil(window.screen, "Precondition: the screen-change handler returns early without window.screen")
        // Startup focus and attach paths call forceRefresh, which re-reads the
        // window's backing scale. Let them finish so only the notification can
        // repair the scale below.
        XCTAssertTrue(
            waitForForceRefreshQuiet(surface, quietFor: 0.5, timeout: 5),
            "Precondition: startup refreshes should stop; count=\(surface.debugForceRefreshCount())"
        )

        // The window lands on a display with another scale and AppKit skips
        // the backing-properties callback.
        let refreshesBeforeMove = surface.debugForceRefreshCount()
        let movedScale = originalScale + 1
        window.movedBackingScaleFactor = movedScale
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(
            surface.appliedContentScale,
            originalScale,
            "Precondition: with no callback and no screen change nothing re-applies the scale, " +
                "so a repair below comes from the notification " +
                "(forceRefresh calls during the wait: \(surface.debugForceRefreshCount() - refreshesBeforeMove))"
        )

        // Act
        NotificationCenter.default.post(name: NSWindow.didChangeScreenNotification, object: window)

        // Assert
        XCTAssertTrue(
            waitUntil(timeout: 2) { surface.appliedContentScale == movedScale },
            "The screen change should apply the moved window's backing scale \(movedScale); " +
                "runtime still at \(String(describing: surface.appliedContentScale))"
        )
    }
}
