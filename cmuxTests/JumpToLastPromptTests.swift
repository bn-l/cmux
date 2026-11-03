import AppKit
import CMUXAgentLaunch
import Foundation
import Testing

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

/// Jump to Last Prompt (upstream manaflow-ai/cmux#18951) on the fork's
/// per-panel prompt log, fed by UserPromptSubmit feed events.
@MainActor
@Suite(.serialized)
struct JumpToLastPromptTests {
    private typealias Target = AppDelegate.LastPromptTarget

    private static func target(_ seconds: TimeInterval, workspace: UUID = UUID(), panel: UUID = UUID()) -> Target {
        Target(workspaceId: workspace, panelId: panel, submittedAt: Date(timeIntervalSince1970: seconds))
    }

    // MARK: - Ordering

    @Test func newestIsNilWithoutCandidates() {
        #expect(Target.newest(in: []) == nil)
    }

    @Test func newestFirstOrdersEveryCandidateFromTheMostRecentSubmit() {
        let older = Self.target(100)
        let newest = Self.target(300)
        let middle = Self.target(200)

        #expect(Target.newestFirst([older, newest, middle]) == [newest, middle, older])
        #expect(Target.newest(in: [middle, older, newest]) == newest)
    }

    @Test func equalSubmitTimesResolveTheSameWayInAnyOrder() throws {
        let lowWorkspace = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000001"))
        let highWorkspace = try #require(UUID(uuidString: "00000000-0000-0000-0000-000000000002"))
        let a = Self.target(100, workspace: lowWorkspace)
        let b = Self.target(100, workspace: highWorkspace)

        #expect(Target.newest(in: [a, b]) == a)
        #expect(Target.newest(in: [b, a]) == a)
    }

    // MARK: - End to end through the app delegate

    /// The UserPromptSubmit side effect records the hook's surface; the jump
    /// then selects that workspace and panel from another workspace, and a
    /// closed panel's entry never becomes a target.
    @Test func promptSubmitRecordsTheHookSurfaceAndTheJumpFocusesIt() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            AppDelegate.shared = appDelegate
            defer {
                for context in Array(appDelegate.mainWindowContexts.values) {
                    appDelegate.unregisterMainWindowContextForTesting(windowId: context.windowId)
                }
                AppDelegate.shared = previousAppDelegate
            }

            // Arrange: two workspaces in a registered window.
            let manager = TabManager()
            let first = try #require(manager.selectedWorkspace)
            let second = manager.addWorkspace(select: false)
            let third = manager.addWorkspace(select: false)
            let secondPanel = try #require(second.focusedPanelId)
            let thirdPanel = try #require(third.focusedPanelId)
            let windowId = appDelegate.registerMainWindowContextForTesting(tabManager: manager)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 500, height: 320),
                styleMask: [.titled, .closable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.identifier = NSUserInterfaceItemIdentifier("cmux.main.\(windowId.uuidString)")
            defer { window.orderOut(nil) }

            // The event the CLI's prompt-submit hook pushes, decoded the way
            // feed.push decodes it.
            @MainActor func promptSubmit(workspace: Workspace, surface: UUID) throws {
                let json = """
                {"session_id":"jump-test","hook_event_name":"UserPromptSubmit","_source":"claude",\
                "workspace_id":"\(workspace.id.uuidString)","surface_id":"\(surface.uuidString)"}
                """
                let event = try JSONDecoder().decode(WorkstreamEvent.self, from: Data(json.utf8))
                let rawWorkspaceId = try #require(event.workspaceId)
                let workspaceId = try #require(UUID(uuidString: rawWorkspaceId))
                TerminalController.shared.applyPromptSubmit(
                    workspaceId: workspaceId,
                    surfaceId: event.surfaceId,
                    message: "hello",
                    iMessageModeEnabled: false
                )
            }

            // Act: prompts in the second, then the third workspace; the third
            // panel then closes.
            try promptSubmit(workspace: second, surface: secondPanel)
            try promptSubmit(workspace: third, surface: thirdPanel)
            #expect(appDelegate.lastPromptSubmissions.submittedAtByPanelId[secondPanel] != nil)
            #expect(appDelegate.lastPromptSubmissions.submittedAtByPanelId[thirdPanel] != nil)
            manager.closeWorkspace(third)
            manager.selectWorkspace(first)
            let jumped = appDelegate.jumpToLastPrompt()

            // Assert
            #expect(jumped?.panelId == secondPanel, "The newest live prompt target is the second workspace's panel")
            #expect(jumped?.workspaceId == second.id)
            #expect(manager.selectedTabId == second.id)
            #expect(second.focusedPanelId == secondPanel)
            #expect(appDelegate.lastPromptSubmissions.submittedAtByPanelId[thirdPanel] == nil, "Closed panels are pruned")
        }
    }

    @Test func jumpWithNoPromptHasNowhereToGo() async throws {
        try await AppContextSerialGate.withExclusiveAppContext {
            let previousAppDelegate = AppDelegate.shared
            let appDelegate = AppDelegate()
            AppDelegate.shared = appDelegate
            defer { AppDelegate.shared = previousAppDelegate }

            #expect(appDelegate.jumpToLastPrompt() == nil)
        }
    }
}
