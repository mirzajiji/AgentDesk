import AgentDeskSecurity
import Foundation

public enum JiraMutationError: Error, Equatable, Sendable {
    /// Jira may have applied the request. Reconcile observed state before any new attempt.
    case outcomeUnknown
    case rejected(status: Int)
}

public struct JiraCommentReceipt: Sendable {
    public let id: String
    public let content: RedactedText
}

/// Internal transport boundary; the runtime must authorize the exact draft before sending.
enum JiraCommentWrite {
    static func make(_ draft: JiraCommentDraft, resource: JiraCloudResource,
                     tokens: JiraOAuthTokens, now: Date) throws -> URLRequest {
        guard now.timeIntervalSince1970.isFinite, tokens.expiresAt > now else { throw JiraServiceError.authenticationRequired }
        guard tokens.scopes.contains("write:jira-work"), resource.scopes.contains("write:jira-work") else {
            throw JiraServiceError.accessDenied
        }
        var request = URLRequest(url: resource.apiOrigin.appendingPathComponent("rest/api/3/issue")
            .appendingPathComponent(draft.identifier).appendingPathComponent("comment"))
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        tokens.accessToken.withBytes { request.setValue("Bearer " + String(decoding: $0, as: UTF8.self), forHTTPHeaderField: "Authorization") }
        request.httpBody = draft.body
        return request
    }

    static func decode(_ response: JiraHTTPResponse, context: RedactionContext, redactor: ContentRedactor) throws -> JiraCommentReceipt {
        // Only explicit request/auth/permission/size/rate rejections are classified as rejected.
        if [400, 401, 403, 404, 413, 429].contains(response.status) { throw JiraMutationError.rejected(status: response.status) }
        guard response.status == 201, response.body.count <= 262_144,
              let text = String(data: response.body, encoding: .utf8) else { throw JiraMutationError.outcomeUnknown }
        struct Receipt: Decodable { let id: String }
        guard let receipt = try? JSONDecoder().decode(Receipt.self, from: response.body),
              !receipt.id.isEmpty, receipt.id.utf8.count <= 128,
              receipt.id.utf8.allSatisfy({ (48...57).contains($0) }) else { throw JiraMutationError.outcomeUnknown }
        return try JiraCommentReceipt(id: receipt.id, content: redactor.redactJSON(text, in: context))
    }
}
