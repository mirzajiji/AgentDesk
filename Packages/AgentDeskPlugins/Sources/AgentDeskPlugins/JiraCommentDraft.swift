import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// A scoped, sanitized comment draft. Preparing it never sends a request or grants permission.
public struct JiraCommentDraft: Sendable {
    public let identifier: String
    public let content: RedactedText
    let body: Data

    public init(identifier: String, content: RedactedText) throws {
        guard JiraIssueRead.validIdentifier(identifier), !content.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              content.text.utf8.count <= 32_768 else { throw AuthorizationError.invalidInput }
        struct Payload: Encodable { let body: JiraTextDocument }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        body = try encoder.encode(Payload(body: JiraTextDocument(content.text)))
        guard body.count <= 262_144 else { throw AuthorizationError.invalidInput }
        self.identifier = identifier; self.content = content
    }

    public func prepare(id: UUID = UUID(), configuration: JiraConnectionConfiguration, configurationRevision: Int,
                        permissions: PluginPermissions, cloudID: UUID, runID: RunID, agentID: AgentID? = nil) throws -> PreparedPluginAction {
        guard content.context.scope == configuration.scope, content.context.environmentID == configuration.environmentID,
              content.context.runID == runID else { throw AuthorizationError.scopeMismatch }
        struct Resource: Encodable { let cloudID: UUID; let identifier: String }
        struct Invocation: Encodable { let schemaVersion = 1; let kind = "addComment"; let body: Data }
        return try PreparedPluginAction(id: id, configuration: configuration, configurationRevision: configurationRevision,
            permissions: permissions, capability: .commentsWrite,
            resource: .canonical(Resource(cloudID: cloudID, identifier: identifier)),
            payload: .canonical(Invocation(body: body)), runID: runID, agentID: agentID)
    }
}
