import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// A snapshot of explicitly masked image evidence, not an assertion that all sensitive pixels were found.
/// Preparing this value grants no upload authority; the exact image still requires external-write review.
public struct JiraImageAttachmentDraft: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let identifier: String
    public let filename: RedactedText
    public let context: RedactionContext
    public let width: Int
    public let height: Int
    public let maskCount: Int
    public let byteCount: Int
    let boundary: String
    let body: Data
    public var description: String { "<private Jira image attachment draft>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["content": description]) }

    public init(identifier: String, filename: RedactedText, image: MaskedImageEvidence) throws {
        guard JiraIssueRead.validIdentifier(identifier), filename.context == image.context,
              (5...128).contains(filename.text.utf8.count), filename.text.lowercased().hasSuffix(".png"),
              filename.text.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
            throw AuthorizationError.invalidInput
        }
        let png = try image.withPNG(in: filename.context) { $0 }
        let boundary = "ADesk-" + (try ActionFingerprint(bytes: png)).rawValue
        guard png.range(of: Data(boundary.utf8)) == nil else { throw AuthorizationError.invalidInput }
        var body = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename.text)\"\r\nContent-Type: image/png\r\n\r\n".utf8)
        body.append(png)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        self.identifier = identifier; self.filename = filename; self.context = image.context
        self.width = image.width; self.height = image.height; self.maskCount = image.maskCount
        self.byteCount = png.count; self.boundary = boundary; self.body = body
    }

    public func prepare(id: UUID = UUID(), configuration: JiraConnectionConfiguration, configurationRevision: Int,
                        permissions: PluginPermissions, cloudID: UUID, runID: RunID, agentID: AgentID? = nil) throws -> PreparedPluginAction {
        guard context.scope == configuration.scope, context.environmentID == configuration.environmentID,
              context.runID == runID else { throw AuthorizationError.scopeMismatch }
        struct Resource: Encodable { let cloudID: UUID; let identifier: String }
        struct Invocation: Encodable { let kind = "attachMaskedImage"; let schemaVersion = 1; let body: ActionFingerprint; let maskCount: Int }
        return try PreparedPluginAction(id: id, configuration: configuration, configurationRevision: configurationRevision,
            permissions: permissions, capability: .attachmentsAdd,
            resource: .canonical(Resource(cloudID: cloudID, identifier: identifier)),
            payload: .canonical(Invocation(body: ActionFingerprint(bytes: body), maskCount: maskCount)), runID: runID, agentID: agentID)
    }
}
