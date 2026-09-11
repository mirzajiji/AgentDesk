import AgentDeskCore
import AgentDeskSecurity
import Foundation

struct JiraAttachmentMetadata: Sendable {
    let id: String
    let cloudID: UUID
    let size: Int64
    let content: RedactedText
}

/// Metadata URLs and filenames are evidence only, never filesystem paths or request destinations.
enum JiraAttachmentRead {
    static func make(id: String, resource: JiraCloudResource, tokens: JiraOAuthTokens, now: Date) throws -> URLRequest {
        guard !id.isEmpty, id.utf8.count <= 128, id.utf8.allSatisfy({ (48...57).contains($0) }) else {
            throw JiraTransportError.invalidRequest
        }
        var request = try JiraIssueRead.make(identifier: id, resource: resource, tokens: tokens, now: now)
        request.url = resource.apiOrigin.appendingPathComponent("rest/api/3/attachment").appendingPathComponent(id)
        return request
    }

    static func decode(_ response: JiraHTTPResponse, expectedID: String, cloudID: UUID, context: RedactionContext,
                       redactor: ContentRedactor) throws -> JiraAttachmentMetadata {
        try JiraResponseStatus.validate(response.status)
        guard response.body.count <= 262_144, let text = String(data: response.body, encoding: .utf8) else {
            throw JiraServiceError.invalidResponse
        }
        struct Metadata: Decodable { let id: String; let filename: String; let size: Int64; let mimeType: String }
        let metadata: Metadata
        do { metadata = try JSONDecoder().decode(Metadata.self, from: response.body) }
        catch { throw JiraServiceError.invalidResponse }
        guard metadata.id == expectedID, !metadata.id.isEmpty, metadata.id.utf8.count <= 128,
              metadata.id.utf8.allSatisfy({ (48...57).contains($0) }), metadata.size >= 0,
              !metadata.filename.isEmpty, metadata.filename.utf8.count <= 4096,
              !metadata.mimeType.isEmpty, metadata.mimeType.utf8.count <= 256,
              !metadata.filename.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              !metadata.mimeType.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw JiraServiceError.invalidResponse
        }
        return JiraAttachmentMetadata(id: metadata.id, cloudID: cloudID, size: metadata.size,
            content: try redactor.redactJSON(text, in: context))
    }

    static func load(id: String, configuration: JiraConnectionConfiguration, resource: JiraCloudResource,
                     tokens: JiraOAuthTokens, context: RedactionContext, redactor: ContentRedactor,
                     now: Date, transport: JiraHTTPTransport) async throws -> JiraAttachmentMetadata {
        try Task.checkCancellation()
        guard configuration.enabled, context.scope == configuration.scope,
              context.environmentID == configuration.environmentID, redactor.context == context else { throw AuthorizationError.scopeMismatch }
        let response = try await transport.send(make(id: id, resource: resource, tokens: tokens, now: now), maximumResponseBytes: 262_144)
        try Task.checkCancellation()
        return try decode(response, expectedID: id, cloudID: resource.id, context: context, redactor: redactor)
    }
}
