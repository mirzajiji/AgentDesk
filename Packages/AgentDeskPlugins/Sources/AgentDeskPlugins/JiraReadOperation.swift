import AgentDeskCore
import Foundation

/// A concrete invocation. This value describes intent and does not grant network authority.
public enum JiraReadOperation: Equatable, Sendable {
    case issue(identifier: String)
    case comments(identifier: String, startAt: Int, limit: Int)
    case attachmentSettings
    case attachmentMetadata(id: String)
    case attachmentContent(id: String, expectedSize: Int64, maximumBytes: Int)

    public var capability: PluginCapability {
        switch self {
        case .issue: .issuesRead
        case .comments: .commentsRead
        case .attachmentSettings, .attachmentMetadata, .attachmentContent: .attachmentsRead
        }
    }

    public func prepare(id: UUID = UUID(), configuration: JiraConnectionConfiguration, configurationRevision: Int,
                        permissions: PluginPermissions, cloudID: UUID, runID: RunID, agentID: AgentID? = nil) throws -> PreparedPluginAction {
        struct Invocation: Encodable {
            let schemaVersion = 1
            let kind: String
            let identifier: String
            let startAt: Int?
            let limit: Int?
            let expectedSize: Int64?
            let maximumBytes: Int?
        }
        let invocation: Invocation
        switch self {
        case .issue(let identifier):
            guard JiraIssueRead.validIdentifier(identifier) else { throw AuthorizationError.invalidInput }
            invocation = .init(kind: "issue", identifier: identifier, startAt: nil, limit: nil, expectedSize: nil, maximumBytes: nil)
        case .comments(let identifier, let startAt, let limit):
            guard JiraIssueRead.validIdentifier(identifier), (0...1_000_000).contains(startAt), (1...100).contains(limit) else { throw AuthorizationError.invalidInput }
            invocation = .init(kind: "comments", identifier: identifier, startAt: startAt, limit: limit, expectedSize: nil, maximumBytes: nil)
        case .attachmentSettings:
            invocation = .init(kind: "attachmentSettings", identifier: "attachment-settings", startAt: nil, limit: nil, expectedSize: nil, maximumBytes: nil)
        case .attachmentMetadata(let identifier):
            try Self.validateAttachmentID(identifier)
            invocation = .init(kind: "attachmentMetadata", identifier: identifier, startAt: nil, limit: nil, expectedSize: nil, maximumBytes: nil)
        case .attachmentContent(let identifier, let size, let limit):
            try Self.validateAttachmentID(identifier)
            guard (1...8_388_608).contains(limit), size >= 0, size <= limit else { throw AuthorizationError.invalidInput }
            invocation = .init(kind: "attachmentContent", identifier: identifier, startAt: nil, limit: nil, expectedSize: size, maximumBytes: limit)
        }
        struct Resource: Encodable { let cloudID: UUID; let identifier: String }
        return try PreparedPluginAction(id: id, configuration: configuration, configurationRevision: configurationRevision,
            permissions: permissions, capability: capability, resource: .canonical(Resource(cloudID: cloudID, identifier: invocation.identifier)),
            payload: .canonical(invocation), runID: runID, agentID: agentID)
    }

    private static func validateAttachmentID(_ id: String) throws {
        guard !id.isEmpty, id.utf8.count <= 128, id.utf8.allSatisfy({ (48...57).contains($0) }) else { throw AuthorizationError.invalidInput }
    }
}
