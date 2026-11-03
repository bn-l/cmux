import CMUXAgentLaunch
import Foundation

extension WorkstreamEvent {
    var submittedPromptMessage: String? {
        guard hookEventName == .userPromptSubmit else { return nil }
        let contextMessage = context?.lastUserMessage.flatMap(Self.normalizedPromptText)
        return Self.messageText(fromJSON: toolInputJSON, keys: Self.promptMessageKeys)
            ?? contextMessage
            ?? Self.messageText(fromJSON: extraFieldsJSON, keys: Self.promptMessageKeys)
    }

    private static let promptMessageKeys = ["prompt", "text", "message", "body"]

    private static func messageText(fromJSON jsonString: String?, keys: [String]) -> String? {
        guard let jsonString else { return nil }
        guard let data = jsonString.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        else {
            return normalizedPromptText(jsonString)
        }

        if let string = value as? String {
            return normalizedPromptText(string)
        }
        guard let dict = value as? [String: Any] else { return nil }
        return messageText(from: dict, keys: keys)
    }

    private static func messageText(from dict: [String: Any], keys: [String]) -> String? {
        if let direct = firstMessageString(in: dict, keys: keys) {
            return direct
        }
        for key in ["notification", "data"] {
            if let nested = dict[key] as? [String: Any],
               let nestedMessage = firstMessageString(in: nested, keys: keys) {
                return nestedMessage
            }
        }
        return nil
    }

    private static func firstMessageString(in dict: [String: Any], keys: [String]) -> String? {
        for key in keys {
            guard let value = dict[key] as? String,
                  let normalized = normalizedPromptText(value) else { continue }
            return normalized
        }
        return nil
    }

    private static func normalizedPromptText(_ value: String) -> String? {
        let normalized = value
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }
}

extension TabManager {
    /// Records a submitted agent prompt on its workspace (the sidebar's
    /// `latestSubmittedMessage` / `latestConversationMessage`) and publishes
    /// `workspace.prompt.submitted` when there was text to record. The
    /// workspace keeps its sidebar position. Returns nil when the workspace
    /// is not in this TabManager.
    @discardableResult
    func handlePromptSubmit(
        workspaceId: UUID,
        message: String?
    ) -> (messageRecorded: Bool, index: Int)? {
        guard let index = tabs.firstIndex(where: { $0.id == workspaceId }) else {
            return nil
        }
        let messageRecorded = tabs[index].recordSubmittedMessage(message)
        if messageRecorded {
            CmuxEventBus.shared.publishWorkspacePromptSubmitted(
                workspaceId: workspaceId,
                message: message,
                preview: Workspace.conversationMessagePreview(from: message)
            )
        }
        return (messageRecorded, index)
    }
}

extension Workspace {
    static func conversationMessagePreview(from message: String?, maxLength: Int = 240) -> String? {
        guard let message else { return nil }
        let collapsed = message
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !collapsed.isEmpty else { return nil }
        guard collapsed.count > maxLength else { return collapsed }
        return "\(collapsed.prefix(maxLength))..."
    }
}
