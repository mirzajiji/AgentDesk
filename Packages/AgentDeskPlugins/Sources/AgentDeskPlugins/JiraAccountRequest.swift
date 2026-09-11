import Foundation

/// Internal authentication probe, called by the connection lifecycle after site discovery.
/// OAuth scopes constrain the remote grant; they do not replace AgentDesk's action policy.
enum JiraAccountRequest {
    static func make(resource: JiraCloudResource, tokens: JiraOAuthTokens, now: Date) throws -> URLRequest {
        guard now.timeIntervalSince1970.isFinite, tokens.expiresAt > now else {
            throw JiraServiceError.authenticationRequired
        }
        guard tokens.scopes.contains("read:jira-user"), resource.scopes.contains("read:jira-user") else {
            throw JiraServiceError.accessDenied
        }
        var request = URLRequest(url: resource.apiOrigin.appendingPathComponent("rest/api/3/myself"))
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        tokens.accessToken.withBytes {
            request.setValue("Bearer " + String(decoding: $0, as: UTF8.self), forHTTPHeaderField: "Authorization")
        }
        return request
    }

    static func load(resource: JiraCloudResource, tokens: JiraOAuthTokens, now: Date,
                     transport: JiraHTTPTransport) async throws -> JiraCloudAccount {
        try Task.checkCancellation()
        let request = try make(resource: resource, tokens: tokens, now: now)
        let response = try await transport.send(request, maximumResponseBytes: 262_144)
        try Task.checkCancellation()
        return try JiraCloudAccount.decode(response)
    }
}
