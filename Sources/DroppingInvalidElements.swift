import Foundation
import OSLog

/// Decodes a persisted array one element at a time and drops (and logs) the
/// elements that no longer decode, instead of failing the whole document.
///
/// Used for lists where one stale element — e.g. a panel whose type has since
/// been removed, like the right sidebar's Files/Find/Vault panes — must not
/// discard everything else: a workspace's panels in the session file and the
/// reopen-closed-item history. Encodes as a plain array, so the stored JSON
/// keeps its shape.
@propertyWrapper
struct DroppingInvalidElements<Element: Codable>: Codable {
    var wrappedValue: [Element]

    init(wrappedValue: [Element]) {
        self.wrappedValue = wrappedValue
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var elements: [Element] = []
        while !container.isAtEnd {
            do {
                elements.append(try container.decode(Element.self))
            } catch {
                // A failed decode leaves the container on the same element.
                _ = try container.decode(SkippedElement.self)
                Self.logger.error(
                    "dropped undecodable \(String(describing: Element.self), privacy: .public) at index \(container.currentIndex - 1): \(String(describing: error), privacy: .public)"
                )
            }
        }
        wrappedValue = elements
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(wrappedValue)
    }

    private struct SkippedElement: Decodable {
        init(from decoder: Decoder) {}
    }

    private static var logger: Logger {
        Logger(subsystem: "com.cmuxterm.app", category: "persistence")
    }
}

extension DroppingInvalidElements: Sendable where Element: Sendable {}
extension DroppingInvalidElements: Equatable where Element: Equatable {}
