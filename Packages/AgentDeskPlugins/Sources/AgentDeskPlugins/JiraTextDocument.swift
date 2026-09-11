import AgentDeskCore
import Foundation

/// The supported plain-text subset of Atlassian Document Format.
struct JiraTextDocument: Encodable, Sendable {
    struct TextNode: Encodable, Sendable { let type = "text"; let text: String }
    struct Paragraph: Encodable, Sendable { let type = "paragraph"; let content: [TextNode] }
    let type = "doc"
    let version = 1
    let content: [Paragraph]
    init(_ text: String) throws {
        guard text.utf8.count <= 32_768 else { throw AuthorizationError.invalidInput }
        content = text.components(separatedBy: "\n").map { Paragraph(content: $0.isEmpty ? [] : [TextNode(text: $0)]) }
    }
}
