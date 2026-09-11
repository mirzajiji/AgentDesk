import AgentDeskSecurity
import Foundation

public struct JiraAttachmentReceipt: Sendable {
    public let id: String
    public let content: RedactedText
}

/// Transport construction only; callers must authorize the exact draft before sending.
enum JiraAttachmentWrite {
    static func make(_ draft: JiraTextAttachmentDraft, resource: JiraCloudResource,
                     tokens: JiraOAuthTokens, now: Date) throws -> URLRequest {
        try make(body: draft.body, boundary: draft.boundary, identifier: draft.identifier, resource: resource, tokens: tokens, now: now)
    }
    static func make(_ draft: JiraImageAttachmentDraft, resource: JiraCloudResource,
                     tokens: JiraOAuthTokens, now: Date) throws -> URLRequest {
        try make(body: draft.body, boundary: draft.boundary, identifier: draft.identifier, resource: resource, tokens: tokens, now: now)
    }
    private static func make(body: Data, boundary: String, identifier: String, resource: JiraCloudResource,
                             tokens: JiraOAuthTokens, now: Date) throws -> URLRequest {
        guard now.timeIntervalSince1970.isFinite, tokens.expiresAt > now else { throw JiraServiceError.authenticationRequired }
        guard tokens.scopes.contains("write:jira-work"), resource.scopes.contains("write:jira-work") else {
            throw JiraServiceError.accessDenied
        }
        var request = URLRequest(url: resource.apiOrigin.appendingPathComponent("rest/api/3/issue")
            .appendingPathComponent(identifier).appendingPathComponent("attachments"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("no-check", forHTTPHeaderField: "X-Atlassian-Token")
        tokens.accessToken.withBytes { request.setValue("Bearer " + String(decoding: $0, as: UTF8.self), forHTTPHeaderField: "Authorization") }
        request.httpBody = body
        return request
    }
    static func decode(_ response: JiraHTTPResponse, draft: JiraTextAttachmentDraft,
                       redactor: ContentRedactor) throws -> JiraAttachmentReceipt {
        try decode(response, filename: draft.filename.text, byteCount: draft.content.text.utf8.count, context: draft.content.context, redactor: redactor)
    }
    static func decode(_ response: JiraHTTPResponse, draft: JiraImageAttachmentDraft,
                       redactor: ContentRedactor) throws -> JiraAttachmentReceipt {
        try decode(response, filename: draft.filename.text, byteCount: draft.byteCount, context: draft.context, redactor: redactor)
    }
    private static func decode(_ response: JiraHTTPResponse, filename: String, byteCount: Int,
                               context: RedactionContext, redactor: ContentRedactor) throws -> JiraAttachmentReceipt {
        if [400, 401, 403, 404, 413, 429].contains(response.status) { throw JiraMutationError.rejected(status: response.status) }
        struct Receipt: Decodable { let id: String; let filename: String; let size: Int }
        guard response.status == 200, response.body.count <= 262_144,
              let text = String(data: response.body, encoding: .utf8),
              let receipts = try? JSONDecoder().decode([Receipt].self, from: response.body), receipts.count == 1,
              let receipt = receipts.first, !receipt.id.isEmpty, receipt.id.utf8.count <= 128,
              receipt.id.utf8.allSatisfy({ (48...57).contains($0) }),
              receipt.filename == filename, receipt.size == byteCount else {
            throw JiraMutationError.outcomeUnknown
        }
        return try JiraAttachmentReceipt(id: receipt.id, content: redactor.redactJSON(text, in: context))
    }
}
