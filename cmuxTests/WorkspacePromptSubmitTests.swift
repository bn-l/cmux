import Foundation
import Testing
import CMUXAgentLaunch

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

@MainActor
@Suite(.serialized)
struct WorkspacePromptSubmitTests {
    @Test func testPromptSubmitRecordsMessageAndPublishesEventWithoutReordering() throws {
        // Arrange: three workspaces, the second selected. A user who once
        // enabled the removed iMessage Mode still has `app.iMessageMode` set in
        // their defaults; it must not bring the reorder back.
        let defaults = UserDefaults.standard
        let legacyIMessageModeKey = "app.iMessageMode"
        let previousLegacyValue = defaults.object(forKey: legacyIMessageModeKey)
        defaults.set(true, forKey: legacyIMessageModeKey)
        defer {
            if let previousLegacyValue {
                defaults.set(previousLegacyValue, forKey: legacyIMessageModeKey)
            } else {
                defaults.removeObject(forKey: legacyIMessageModeKey)
            }
        }
        CmuxEventBus.shared.resetForTesting()
        defer { CmuxEventBus.shared.resetForTesting() }
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let third = manager.addWorkspace(select: false, placementOverride: .end)
        manager.selectWorkspace(second)
        CmuxEventBus.shared.resetForTesting()

        // Act
        let outcome = try #require(
            manager.handlePromptSubmit(
                workspaceId: third.id,
                message: "  implement this\n\nnow  "
            )
        )

        // Assert: recorded in place, one prompt event, no reorder event.
        #expect(outcome.messageRecorded)
        #expect(outcome.index == 2)
        #expect(manager.tabs.map(\.id) == [first.id, second.id, third.id])
        #expect(manager.selectedTabId == second.id)
        #expect(third.latestSubmittedMessage == "implement this now")
        #expect(third.latestConversationMessage == "implement this now")
        #expect(third.latestSubmittedAt != nil)
        let events = CmuxEventBus.shared.retainedSnapshot()
        #expect(events.compactMap { $0["name"] as? String } == ["workspace.prompt.submitted"])
        let submitted = try #require(events.first)
        #expect(submitted["workspace_id"] as? String == third.id.uuidString)
        let payload = try #require(submitted["payload"] as? [String: Any])
        #expect(payload["message_preview"] as? String == "implement this now")
        #expect(payload["message"] is NSNull, "the raw prompt text stays redacted")
    }

    @Test func testPromptSubmitForWorkspaceOutsideManagerReturnsNil() {
        let manager = TabManager()
        let orderBefore = manager.tabs.map(\.id)

        let outcome = manager.handlePromptSubmit(workspaceId: UUID(), message: "lost")

        #expect(outcome == nil)
        #expect(manager.tabs.map(\.id) == orderBefore)
    }

    @Test func testBlankPromptSubmitDoesNotRecordTimestampOrPublishEvent() throws {
        let manager = TabManager()
        let second = manager.addWorkspace(select: false, placementOverride: .end)
        let sequenceBeforeSubmit = CmuxEventBus.shared.latestSequence

        let outcome = try #require(
            manager.handlePromptSubmit(
                workspaceId: second.id,
                message: " \n "
            )
        )

        #expect(!outcome.messageRecorded)
        #expect(outcome.index == 1)
        #expect(second.latestConversationMessage == nil)
        #expect(second.latestSubmittedAt == nil)
        #expect(CmuxEventBus.shared.latestSequence == sequenceBeforeSubmit)
    }

    @Test func testFeedPromptSubmitEventExtractsToolInputMessage() throws {
        let manager = TabManager()
        let first = manager.tabs[0]
        let second = manager.addWorkspace(select: false, placementOverride: .end)

        let event = WorkstreamEvent(
            sessionId: "opencode-session",
            hookEventName: .userPromptSubmit,
            source: "opencode",
            workspaceId: second.id.uuidString,
            toolInputJSON: #"{"prompt":"  shipped from feed\npath  "}"#,
            context: WorkstreamContext(lastUserMessage: "fallback message")
        )

        let outcome = try #require(
            manager.handlePromptSubmit(
                workspaceId: second.id,
                message: event.submittedPromptMessage
            )
        )

        #expect(outcome.messageRecorded)
        #expect(outcome.index == 1)
        #expect(manager.tabs.map(\.id) == [first.id, second.id])
        #expect(second.latestConversationMessage == "shipped from feed path")
    }

    @Test func testFeedPromptSubmitEventFallsBackToContextMessage() {
        let event = WorkstreamEvent(
            sessionId: "agent-session",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: UUID().uuidString,
            context: WorkstreamContext(lastUserMessage: "from context")
        )

        #expect(event.submittedPromptMessage == "from context")
    }

    @Test func testFeedPromptSubmitSkipsBlankContextBeforeExtraFields() {
        let event = WorkstreamEvent(
            sessionId: "agent-session",
            hookEventName: .userPromptSubmit,
            source: "codex",
            workspaceId: UUID().uuidString,
            context: WorkstreamContext(lastUserMessage: " \n "),
            extraFieldsJSON: #"{"message":"from extra fields"}"#
        )

        #expect(event.submittedPromptMessage == "from extra fields")
    }

    @Test func testBlankSubmittedMessageDoesNotClearRecordedPreview() {
        let workspace = Workspace()

        #expect(workspace.recordSubmittedMessage("keep this preview"))
        #expect(!workspace.recordSubmittedMessage(" \n "))
        #expect(workspace.latestConversationMessage == "keep this preview")
        #expect(workspace.latestSubmittedAt != nil)
    }
}
