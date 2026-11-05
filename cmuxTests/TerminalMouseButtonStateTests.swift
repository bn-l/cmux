import AppKit
import CmuxTerminal
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

#if DEBUG
/// Drives real `GhosttyNSView` handlers against a real surface and asserts on the bytes a
/// mouse-reporting program receives in the pty. See ISSUE_stuck_right_button_nvim_visual_mode.md.
@MainActor
@Suite(.serialized)
struct TerminalMouseButtonStateTests {
    /// A program that switches SGR button-event mouse reporting (what nvim uses) on and off
    /// when told to, and records everything it reads.
    private struct MouseReportingProgram {
        let directory: URL

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("cmux-mouse-button-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = #"""
            import os, select, sys, termios, time, tty
            d = sys.argv[1]
            old = termios.tcgetattr(0)
            tty.setraw(0)
            os.write(1, b"word word word word\r\n")
            open(d + "/up", "w").close()
            out = open(d + "/bytes", "ab", buffering=0)
            cur = ""
            end = time.time() + 120
            while time.time() < end:
                try:
                    c = open(d + "/ctl").read().strip()
                except OSError:
                    c = ""
                if c != cur:
                    cur = c
                    if c == "on":
                        os.write(1, b"\x1b[?1002h\x1b[?1006h")
                    if c == "off":
                        os.write(1, b"\x1b[?1006l\x1b[?1002l")
                    if c == "stop":
                        break
                    open(d + "/ack", "w").write(c)
                if select.select([0], [], [], 0.01)[0]:
                    out.write(os.read(0, 4096))
            termios.tcsetattr(0, termios.TCSADRAIN, old)
            """#
            try script.write(to: directory.appendingPathComponent("probe.py"), atomically: true, encoding: .utf8)
        }

        var command: String {
            "/usr/bin/python3 '\(directory.appendingPathComponent("probe.py").path)' '\(directory.path)'"
        }

        func hasStarted() -> Bool {
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("up").path)
        }

        func setControl(_ value: String) throws {
            try value.write(to: directory.appendingPathComponent("ctl"), atomically: true, encoding: .utf8)
        }

        func acknowledged(_ value: String) -> Bool {
            (try? String(contentsOf: directory.appendingPathComponent("ack"), encoding: .utf8)) == value
        }

        /// SGR reports received so far, as "<code><M|m>", e.g. "34M" for a right-button drag.
        func reports() -> [String] {
            let raw = (try? String(contentsOf: directory.appendingPathComponent("bytes"), encoding: .isoLatin1)) ?? ""
            return raw.components(separatedBy: "\u{1b}[<").dropFirst().map { report in
                let code = report.prefix { $0 != ";" }
                let terminator = report.first { $0 == "M" || $0 == "m" }.map(String.init) ?? "?"
                return "\(code)\(terminator)"
            }
        }

        func cleanUp() {
            try? setControl("stop")
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static func waitUntil(timeout: Duration = .seconds(20), _ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if condition() { return true }
            // Must yield rather than spin the run loop: surface creation finishes on a main-actor task.
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    /// Long enough for bytes written by Ghostty to reach the program's log.
    private static func settle() async {
        try? await Task.sleep(for: .milliseconds(400))
    }

    private static func mouseEvent(
        _ type: NSEvent.EventType,
        in view: GhosttyNSView,
        at point: NSPoint,
        modifierFlags: NSEvent.ModifierFlags = [],
        clickCount: Int = 1
    ) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(
            with: type,
            location: view.convert(point, to: nil),
            modifierFlags: modifierFlags,
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0,
            context: nil,
            eventNumber: 0,
            clickCount: clickCount,
            pressure: 1
        ))
    }

    private static func hover(_ view: GhosttyNSView, fromX: CGFloat) throws {
        for step in 0..<6 {
            view.mouseMoved(with: try mouseEvent(.mouseMoved, in: view, at: NSPoint(x: fromX + CGFloat(step) * 40, y: 200)))
        }
    }

    private static func setCapture(_ on: Bool, program: MouseReportingProgram, surface: TerminalSurface) async throws {
        let value = on ? "on" : "off"
        try program.setControl(value)
        let applied = await waitUntil {
            guard program.acknowledged(value), let runtime = surface.surface else { return false }
            return ghostty_surface_mouse_captured(runtime) == on
        }
        try #require(applied, "program did not switch mouse reporting \(value)")
    }

    // MARK: - Right button

    @MainActor private struct StandaloneTerminal {
        let program: MouseReportingProgram
        let surface: TerminalSurface
        let window: NSWindow
        let view: GhosttyNSView

        func tearDown() {
            program.cleanUp()
            surface.releaseSurfaceForTesting()
            window.orderOut(nil)
        }
    }

    private func makeStandaloneTerminal() async throws -> StandaloneTerminal {
        let program = try MouseReportingProgram()
        let surface = TerminalSurface(
            tabId: UUID(),
            context: GHOSTTY_SURFACE_CONTEXT_SPLIT,
            configTemplate: nil,
            workingDirectory: nil,
            initialCommand: program.command
        )
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 600, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        let contentView = try #require(window.contentView)
        surface.hostedView.frame = contentView.bounds
        surface.hostedView.autoresizingMask = [.width, .height]
        contentView.addSubview(surface.hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        surface.hostedView.setVisibleInUI(true)
        surface.hostedView.setActive(true)
        let view = try #require(findGhosttyNSView(in: surface.hostedView))
        #expect(window.makeFirstResponder(view))
        try #require(await Self.waitUntil { surface.surface != nil }, "no runtime surface")
        try #require(await Self.waitUntil { program.hasStarted() }, "probe program did not start")
        return StandaloneTerminal(program: program, surface: surface, window: window, view: view)
    }

    @Test
    func contextMenuRightClickDoesNotLeaveButtonPressed() async throws {
        let terminal = try await makeStandaloneTerminal()
        defer { terminal.tearDown() }

        _ = terminal.view.menu(for: try Self.mouseEvent(.rightMouseDown, in: terminal.view, at: NSPoint(x: 60, y: 200)))
        try await Self.setCapture(true, program: terminal.program, surface: terminal.surface)
        try Self.hover(terminal.view, fromX: 60)
        await Self.settle()

        #expect(
            terminal.program.reports().isEmpty,
            "Hover after a context-menu right-click must not be reported as a button drag"
        )

        // The empty result above only means something if hover is reported while a button is down.
        terminal.view.rightMouseDown(with: try Self.mouseEvent(.rightMouseDown, in: terminal.view, at: NSPoint(x: 60, y: 200)))
        try Self.hover(terminal.view, fromX: 100)
        await Self.settle()
        #expect(terminal.program.reports().contains("34M"), "Hover with the right button held should report drags")
    }

    @Test
    func contextMenuRightClickStillSelectsTheWordForCopy() async throws {
        let terminal = try await makeStandaloneTerminal()
        defer { terminal.tearDown() }
        let onFirstRowWord = NSPoint(x: 20, y: terminal.view.bounds.height - 10)
        await Self.settle()

        let menu = try #require(terminal.view.menu(for: try Self.mouseEvent(.rightMouseDown, in: terminal.view, at: onFirstRowWord)))

        #expect(
            menu.items.contains { $0.action == Selector(("copy:")) },
            "Right-click on a word selects it on the press, so the menu must offer Copy"
        )
    }

    @Test
    func rightReleaseIsRecordedWhenCaptureEndsBeforeRelease() async throws {
        let terminal = try await makeStandaloneTerminal()
        defer { terminal.tearDown() }

        try await Self.setCapture(true, program: terminal.program, surface: terminal.surface)
        terminal.view.rightMouseDown(with: try Self.mouseEvent(.rightMouseDown, in: terminal.view, at: NSPoint(x: 60, y: 200)))
        await Self.settle()
        #expect(terminal.program.reports() == ["2M"])
        try await Self.setCapture(false, program: terminal.program, surface: terminal.surface)
        terminal.view.rightMouseUp(with: try Self.mouseEvent(.rightMouseUp, in: terminal.view, at: NSPoint(x: 60, y: 200)))
        try await Self.setCapture(true, program: terminal.program, surface: terminal.surface)
        try Self.hover(terminal.view, fromX: 100)
        await Self.settle()

        #expect(
            terminal.program.reports() == ["2M"],
            "A release sent after capture ended must clear the button, so later hover is not reported"
        )
    }

    @Test
    func capturedRightClickReportsPressAndReleaseToTheProgram() async throws {
        let terminal = try await makeStandaloneTerminal()
        defer { terminal.tearDown() }

        try await Self.setCapture(true, program: terminal.program, surface: terminal.surface)
        let point = NSPoint(x: 60, y: 200)
        terminal.view.rightMouseDown(with: try Self.mouseEvent(.rightMouseDown, in: terminal.view, at: point))
        terminal.view.rightMouseUp(with: try Self.mouseEvent(.rightMouseUp, in: terminal.view, at: point))
        await Self.settle()

        #expect(terminal.program.reports() == ["2M", "2m"])
    }

    // MARK: - Focus-transfer click

    private struct SplitTerminals {
        let program: MouseReportingProgram
        let workspace: Workspace
        let window: NSWindow
        let focused: GhosttyNSView
        let target: GhosttyNSView
        let targetPanelId: UUID
        let targetSurface: TerminalSurface
        let restore: () -> Void
    }

    /// Two panes in one workspace. The program runs in `target`, which starts unfocused.
    private func makeSplitTerminals() async throws -> SplitTerminals {
        AppDelegate.installWindowResponderSwizzlesForTesting()
        let appDelegate = AppDelegate.shared ?? AppDelegate()
        let originalTabManager = appDelegate.tabManager
        let manager = TabManager()
        appDelegate.tabManager = manager

        let program = try MouseReportingProgram()
        let workspace = try #require(manager.selectedWorkspace)
        let focusedPanel = try #require(workspace.focusedTerminalPanel)
        let targetPanel = try #require(workspace.newTerminalSplit(
            from: focusedPanel.id,
            orientation: .horizontal,
            focus: false,
            initialCommand: program.command
        ))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1000, height: 400),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        // terminalPointerShouldForwardActivation finds the workspace through this registration.
        appDelegate.registerMainWindow(
            window,
            windowId: UUID(),
            tabManager: manager,
            sidebarState: SidebarState(),
            sidebarSelectionState: SidebarSelectionState()
        )
        let contentView = try #require(window.contentView)
        focusedPanel.hostedView.frame = NSRect(x: 0, y: 0, width: 500, height: 400)
        targetPanel.hostedView.frame = NSRect(x: 500, y: 0, width: 500, height: 400)
        contentView.addSubview(focusedPanel.hostedView)
        contentView.addSubview(targetPanel.hostedView)
        window.makeKeyAndOrderFront(nil)
        window.displayIfNeeded()
        for hosted in [focusedPanel.hostedView, targetPanel.hostedView] {
            hosted.setVisibleInUI(true)
            hosted.setActive(true)
        }
        let focusedView = try #require(findGhosttyNSView(in: focusedPanel.hostedView))
        let targetView = try #require(findGhosttyNSView(in: targetPanel.hostedView))
        // Mirrors the first-responder wiring in WorkspaceContentView: the workspace's focused
        // panel changes as soon as a terminal view becomes first responder.
        for (view, panelId) in [(focusedView, focusedPanel.id), (targetView, targetPanel.id)] {
            view.onFocus = { workspace.focusPanel(panelId, trigger: .terminalFirstResponder) }
        }
        #expect(window.makeFirstResponder(focusedView))

        try #require(await Self.waitUntil { targetPanel.surface.surface != nil }, "no runtime surface for target pane")
        try #require(await Self.waitUntil { program.hasStarted() }, "probe program did not start")
        try await Self.setCapture(true, program: program, surface: targetPanel.surface)
        try #require(workspace.focusedPanelId == focusedPanel.id, "target pane must start unfocused")

        return SplitTerminals(
            program: program,
            workspace: workspace,
            window: window,
            focused: focusedView,
            target: targetView,
            targetPanelId: targetPanel.id,
            targetSurface: targetPanel.surface,
            restore: {
                AppDelegate.clearWindowFirstResponderGuardTesting()
                program.cleanUp()
                window.close()
                appDelegate.tabManager = originalTabManager
            }
        )
    }

    /// Replays what AppKit does for a real click: first responder moves during window dispatch,
    /// through cmux's guard, and only then does `mouseDown` run.
    private static func dispatchPress(_ event: NSEvent, to view: GhosttyNSView) {
        AppDelegate.setWindowFirstResponderGuardTesting(currentEvent: event, hitView: view)
        _ = view.window?.makeFirstResponder(view)
        view.mouseDown(with: event)
        AppDelegate.clearWindowFirstResponderGuardTesting()
    }

    @Test
    func clickThatMovesFocusBetweenPanesNeverReachesTheProgram() async throws {
        let split = try await makeSplitTerminals()
        defer { split.restore() }
        let press = NSPoint(x: 60, y: 200)
        let drift = NSPoint(x: 120, y: 200)

        Self.dispatchPress(try Self.mouseEvent(.leftMouseDown, in: split.target, at: press), to: split.target)
        #expect(split.workspace.focusedPanelId == split.targetPanelId, "The click must still move focus")
        split.target.mouseDragged(with: try Self.mouseEvent(.leftMouseDragged, in: split.target, at: drift))
        split.target.mouseUp(with: try Self.mouseEvent(.leftMouseUp, in: split.target, at: drift))
        await Self.settle()

        #expect(
            !split.target.debugHasPendingLeftMouseReleaseForTesting(),
            "The focus click must not leave a press to release"
        )
        #expect(
            split.program.reports().isEmpty,
            "A focus-transfer click with pointer drift would put nvim in Visual mode if it reached the program"
        )
    }

    @Test
    func clickInTheAlreadyFocusedPaneReachesTheProgram() async throws {
        let split = try await makeSplitTerminals()
        defer { split.restore() }
        let point = NSPoint(x: 60, y: 200)

        Self.dispatchPress(try Self.mouseEvent(.leftMouseDown, in: split.target, at: point), to: split.target)
        split.target.mouseUp(with: try Self.mouseEvent(.leftMouseUp, in: split.target, at: point))
        Self.dispatchPress(try Self.mouseEvent(.leftMouseDown, in: split.target, at: point), to: split.target)
        split.target.mouseUp(with: try Self.mouseEvent(.leftMouseUp, in: split.target, at: point))
        await Self.settle()

        #expect(split.program.reports() == ["0M", "0m"], "Only the second click should be reported")
    }

    @Test
    func focusTransferThatNeverReachedMouseDownDoesNotSwallowTheNextClick() async throws {
        let split = try await makeSplitTerminals()
        defer { split.restore() }
        let point = NSPoint(x: 60, y: 200)

        let abandoned = try Self.mouseEvent(.leftMouseDown, in: split.target, at: point)
        AppDelegate.setWindowFirstResponderGuardTesting(currentEvent: abandoned, hitView: split.target)
        _ = split.window.makeFirstResponder(split.target)
        AppDelegate.clearWindowFirstResponderGuardTesting()
        try await Task.sleep(for: .milliseconds(5))
        split.target.mouseDown(with: try Self.mouseEvent(.leftMouseDown, in: split.target, at: point))
        split.target.mouseUp(with: try Self.mouseEvent(.leftMouseUp, in: split.target, at: point))
        await Self.settle()

        #expect(split.program.reports() == ["0M", "0m"])
    }

    @Test
    func commandClickInAnUnfocusedPaneIsStillForwarded() async throws {
        let split = try await makeSplitTerminals()
        defer { split.restore() }
        let point = NSPoint(x: 60, y: 200)

        Self.dispatchPress(
            try Self.mouseEvent(.leftMouseDown, in: split.target, at: point, modifierFlags: .command),
            to: split.target
        )

        #expect(
            split.target.debugHasPendingLeftMouseReleaseForTesting(),
            "Cmd-click must reach Ghostty so links and paths in an unfocused pane open on the first click"
        )
        split.target.mouseUp(with: try Self.mouseEvent(.leftMouseUp, in: split.target, at: point, modifierFlags: .command))
    }
}
#endif
