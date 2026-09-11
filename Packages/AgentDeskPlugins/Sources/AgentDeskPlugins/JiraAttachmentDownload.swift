import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// Unprocessed private bytes. Callers must redact/extract before display or persistence.
/// Deliberately has no Codable conformance or printable data representation.
public struct JiraAttachmentBytes: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let context: RedactionContext
    let cloudID: UUID
    let attachmentID: String
    private let data: Data
    public var description: String { "<private Jira attachment>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["content": description]) }
    fileprivate init(data: Data, metadata: JiraAttachmentMetadata) {
        self.data = data; context = metadata.content.context; cloudID = metadata.cloudID; attachmentID = metadata.id
    }
    public func withBytes<T>(_ body: (Data) throws -> T) rethrows -> T { try body(data) }
}

enum JiraAttachmentDownload {
    static func make(metadata: JiraAttachmentMetadata, resource: JiraCloudResource, tokens: JiraOAuthTokens,
                     now: Date, maximumBytes: Int) throws -> URLRequest {
        guard metadata.cloudID == resource.id else { throw AuthorizationError.scopeMismatch }
        guard (1...8_388_608).contains(maximumBytes), metadata.size <= maximumBytes else { throw JiraTransportError.responseTooLarge }
        var request = try JiraAttachmentRead.make(id: metadata.id, resource: resource, tokens: tokens, now: now)
        var parts = URLComponents(url: resource.apiOrigin.appendingPathComponent("rest/api/3/attachment/content").appendingPathComponent(metadata.id), resolvingAgainstBaseURL: false)!
        parts.queryItems = [.init(name: "redirect", value: "false")]
        request.url = parts.url
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        return request
    }
    static func decode(_ response: JiraHTTPResponse, metadata: JiraAttachmentMetadata, maximumBytes: Int) throws -> JiraAttachmentBytes {
        try JiraResponseStatus.validate(response.status)
        guard response.status == 200, response.body.count == metadata.size else { throw JiraServiceError.invalidResponse }
        guard (1...8_388_608).contains(maximumBytes), response.body.count <= maximumBytes else { throw JiraTransportError.responseTooLarge }
        return JiraAttachmentBytes(data: response.body, metadata: metadata)
    }
    static func load(metadata: JiraAttachmentMetadata, configuration: JiraConnectionConfiguration, resource: JiraCloudResource,
                     tokens: JiraOAuthTokens, now: Date, maximumBytes: Int, transport: JiraHTTPTransport) async throws -> JiraAttachmentBytes {
        try Task.checkCancellation()
        guard configuration.enabled, metadata.content.context.scope == configuration.scope,
              metadata.content.context.environmentID == configuration.environmentID else { throw AuthorizationError.scopeMismatch }
        let response = try await transport.send(make(metadata: metadata, resource: resource, tokens: tokens, now: now, maximumBytes: maximumBytes), maximumResponseBytes: maximumBytes)
        try Task.checkCancellation()
        return try decode(response, metadata: metadata, maximumBytes: maximumBytes)
    }
}
