import Foundation

/// Conversation text attached to a forwarded agent hook event: the prompt
/// the user just submitted and the agent's final message. The app reads
/// `lastUserMessage` for the workspace prompt record; the events stream
/// reports the context only as a byte length. Unknown keys from older senders
/// are ignored.
public struct WorkstreamContext: Codable, Sendable, Equatable {
    public let lastUserMessage: String?
    public let assistantPreamble: String?

    public init(lastUserMessage: String? = nil, assistantPreamble: String? = nil) {
        self.lastUserMessage = Self.cleaned(lastUserMessage)
        self.assistantPreamble = Self.cleaned(assistantPreamble)
    }

    private enum CodingKeys: String, CodingKey {
        case lastUserMessage
        case assistantPreamble
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            lastUserMessage: try c.decodeIfPresent(String.self, forKey: .lastUserMessage),
            assistantPreamble: try c.decodeIfPresent(String.self, forKey: .assistantPreamble)
        )
    }

    public var isEmpty: Bool {
        lastUserMessage == nil && assistantPreamble == nil
    }

    private static func cleaned(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
