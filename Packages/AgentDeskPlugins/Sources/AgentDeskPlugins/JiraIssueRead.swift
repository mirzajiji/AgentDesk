import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// Evidence preserves both the requested identifier and Jira's resolved key (issues can move).
struct JiraIssueEvidence: Sendable {
    let requestedIdentifier: String
    let resolvedKey: String
    let issueID: String
    let cloudID: UUID
    let observedAt: Date
    let content: RedactedText
}

/// Transport implementation only. The runtime invokes it inside the exact prepared policy action.
enum JiraIssueRead {
    static func validIdentifier(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 128 else { return false }
        return value.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }
    }

    static func make(identifier: String, resource: JiraCloudResource, tokens: JiraOAuthTokens, now: Date) throws -> URLRequest {
        guard validIdentifier(identifier) else { throw JiraTransportError.invalidRequest }
        guard now.timeIntervalSince1970.isFinite, tokens.expiresAt > now else { throw JiraServiceError.authenticationRequired }
        guard tokens.scopes.contains("read:jira-work"), resource.scopes.contains("read:jira-work") else { throw JiraServiceError.accessDenied }
        var components = URLComponents(url: resource.apiOrigin.appendingPathComponent("rest/api/3/issue").appendingPathComponent(identifier), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fields", value: "summary,description,status,issuetype,priority,updated,project")]
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        tokens.accessToken.withBytes { request.setValue("Bearer " + String(decoding: $0, as: UTF8.self), forHTTPHeaderField: "Authorization") }
        return request
    }

    static func load(identifier: String, configuration: JiraConnectionConfiguration, resource: JiraCloudResource,
                     tokens: JiraOAuthTokens, context: RedactionContext, redactor: ContentRedactor,
                     now: Date, transport: JiraHTTPTransport) async throws -> JiraIssueEvidence {
        try Task.checkCancellation()
        guard configuration.enabled, context.scope == configuration.scope,
              context.environmentID == configuration.environmentID, redactor.context == context else {
            throw AuthorizationError.scopeMismatch
        }
        let response = try await transport.send(make(identifier: identifier, resource: resource, tokens: tokens, now: now), maximumResponseBytes: 262_144)
        try Task.checkCancellation()
        try JiraResponseStatus.validate(response.status)
        guard response.body.count <= 262_144, let text = String(data: response.body, encoding: .utf8) else {
            throw JiraServiceError.invalidResponse
        }
        struct Identity: Decodable { let id: String; let key: String }
        let identity: Identity
        do { identity = try JSONDecoder().decode(Identity.self, from: response.body) }
        catch { throw JiraServiceError.invalidResponse }
        guard !identity.id.isEmpty, identity.id.utf8.count <= 128,
              identity.id.utf8.allSatisfy({ (48...57).contains($0) }), validIdentifier(identity.key) else {
            throw JiraServiceError.invalidResponse
        }
        let content = try redactor.redactJSON(text, in: context)
        return JiraIssueEvidence(requestedIdentifier: identifier, resolvedKey: identity.key,
            issueID: identity.id, cloudID: resource.id, observedAt: now, content: content)
    }
}
