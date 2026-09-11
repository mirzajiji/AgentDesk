import AgentDeskCore
import AgentDeskSecurity
import Foundation

extension JiraIssueEvidence {
    /// Binds the visible evidence and Jira revision timestamp, excluding local read time.
    /// Missing revision evidence cannot authorize an edit. This is a preflight comparison,
    /// not a server-side conditional update or a guarantee against concurrent edits.
    func editFingerprint() throws -> ActionFingerprint {
        guard content.text.utf8.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: Data(content.text.utf8)) as? [String: Any],
              let fields = object["fields"] as? [String: Any],
              let updated = fields["updated"] as? String,
              !updated.isEmpty, updated.utf8.count <= 128,
              object["id"] as? String == issueID, object["key"] as? String == resolvedKey else {
            throw JiraServiceError.invalidResponse
        }
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        struct Binding: Encodable {
            let schemaVersion = 1
            let context: RedactionContext
            let cloudID: UUID
            let requestedIdentifier: String
            let evidence: Data
        }
        return try .canonical(Binding(context: content.context, cloudID: cloudID,
            requestedIdentifier: requestedIdentifier, evidence: canonical))
    }
}

/// A read-derived edit baseline. Callers cannot construct evidence without a session read.
public struct JiraIssueSnapshot: Sendable {
    public let identifier: String
    public let resolvedKey: String
    public let content: RedactedText
    public let fingerprint: ActionFingerprint
    public let observedAt: Date
    public let cloudID: UUID

    init(_ evidence: JiraIssueEvidence) throws {
        identifier = evidence.requestedIdentifier
        resolvedKey = evidence.resolvedKey
        content = evidence.content
        fingerprint = try evidence.editFingerprint()
        observedAt = evidence.observedAt
        cloudID = evidence.cloudID
    }

    public func edit(summary: RedactedText? = nil, description: RedactedText? = nil) throws -> JiraIssueEditDraft {
        guard summary.map({ $0.context == content.context }) ?? true,
              description.map({ $0.context == content.context }) ?? true else {
            throw AuthorizationError.scopeMismatch
        }
        return try JiraIssueEditDraft(identifier: identifier, summary: summary,
                                      description: description, expectedIssue: fingerprint)
    }
}
