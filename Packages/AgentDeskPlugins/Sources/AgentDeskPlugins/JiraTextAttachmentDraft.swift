import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// Sanitized text evidence for a single Jira attachment. No local path is read or transmitted.
public struct JiraTextAttachmentDraft: Sendable {
    public let identifier: String
    public let filename: RedactedText
    public let content: RedactedText
    let boundary: String
    let body: Data

    public init(identifier: String, filename: RedactedText, content: RedactedText) throws {
        guard JiraIssueRead.validIdentifier(identifier), filename.context == content.context,
              (1...128).contains(filename.text.utf8.count),
              filename.text != ".", filename.text != "..",
              filename.text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }),
              content.text.utf8.count <= 1_048_576 else { throw AuthorizationError.invalidInput }
        self.identifier = identifier; self.filename = filename; self.content = content
        boundary = "ADesk-" + (try ActionFingerprint(bytes: Data(content.text.utf8))).rawValue
        guard !content.text.contains(boundary) else { throw AuthorizationError.invalidInput }
        var multipart = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename.text)\"\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n".utf8)
        multipart.append(Data(content.text.utf8))
        multipart.append(Data("\r\n--\(boundary)--\r\n".utf8))
        body = multipart
    }
    public func prepare(id: UUID = UUID(), configuration: JiraConnectionConfiguration, configurationRevision: Int,
                        permissions: PluginPermissions, cloudID: UUID, runID: RunID, agentID: AgentID? = nil) throws -> PreparedPluginAction {
        guard content.context.scope == configuration.scope, content.context.environmentID == configuration.environmentID,
              content.context.runID == runID else { throw AuthorizationError.scopeMismatch }
        struct Resource: Encodable { let cloudID: UUID; let identifier: String }
        struct Invocation: Encodable { let kind = "attachTextEvidence"; let schemaVersion = 1; let body: ActionFingerprint }
        return try PreparedPluginAction(id: id, configuration: configuration, configurationRevision: configurationRevision,
            permissions: permissions, capability: .attachmentsAdd,
            resource: .canonical(Resource(cloudID: cloudID, identifier: identifier)),
            payload: .canonical(Invocation(body: ActionFingerprint(bytes: body))), runID: runID, agentID: agentID)
    }
}
