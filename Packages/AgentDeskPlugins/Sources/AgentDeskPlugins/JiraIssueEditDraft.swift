import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// Exact supported field replacement, with the observed issue state bound for preflight revalidation.
public struct JiraIssueEditDraft: Sendable {
    public let identifier: String
    public let summary: RedactedText?
    public let description: RedactedText?
    public let expectedIssue: ActionFingerprint
    public let context: RedactionContext
    let body: Data

    public init(identifier: String, summary: RedactedText? = nil, description: RedactedText? = nil,
                expectedIssue: ActionFingerprint) throws {
        guard JiraIssueRead.validIdentifier(identifier), let context = (summary ?? description)?.context,
              summary.map({ $0.context == context }) ?? true,
              description.map({ $0.context == context }) ?? true else { throw AuthorizationError.invalidInput }
        if let summary {
            guard !summary.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  summary.text.utf16.count <= 255, !summary.text.contains("\n"), !summary.text.contains("\r") else {
                throw AuthorizationError.invalidInput
            }
        }
        struct Fields: Encodable { let summary: String?; let description: JiraTextDocument? }
        struct Payload: Encodable { let fields: Fields }
        let fields = try Fields(summary: summary?.text, description: description.map { try JiraTextDocument($0.text) })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        body = try encoder.encode(Payload(fields: fields))
        guard body.count <= 262_144 else { throw AuthorizationError.invalidInput }
        self.identifier = identifier; self.summary = summary; self.description = description
        self.expectedIssue = expectedIssue; self.context = context
    }
    public func prepare(id: UUID = UUID(), configuration: JiraConnectionConfiguration, configurationRevision: Int,
                        permissions: PluginPermissions, cloudID: UUID, runID: RunID, agentID: AgentID? = nil) throws -> PreparedPluginAction {
        guard context.scope == configuration.scope, context.environmentID == configuration.environmentID,
              context.runID == runID else { throw AuthorizationError.scopeMismatch }
        struct Resource: Encodable { let cloudID: UUID; let identifier: String }
        struct Invocation: Encodable { let schemaVersion = 1; let kind = "editIssue"; let expectedIssue: ActionFingerprint; let body: Data }
        return try PreparedPluginAction(id: id, configuration: configuration, configurationRevision: configurationRevision,
            permissions: permissions, capability: .issuesUpdate,
            resource: .canonical(Resource(cloudID: cloudID, identifier: identifier)),
            payload: .canonical(Invocation(expectedIssue: expectedIssue, body: body)), runID: runID, agentID: agentID)
    }
}
