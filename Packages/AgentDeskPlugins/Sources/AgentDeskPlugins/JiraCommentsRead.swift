import AgentDeskCore
import AgentDeskSecurity
import Foundation

struct JiraCommentsPage: Sendable {
    let startAt: Int
    let total: Int
    let nextStartAt: Int?
    let content: RedactedText
}

/// Each page is a separate bounded read, to be authorized by the runtime before invocation.
enum JiraCommentsRead {
    static func make(identifier: String, startAt: Int, limit: Int, resource: JiraCloudResource,
                     tokens: JiraOAuthTokens, now: Date) throws -> URLRequest {
        guard (0...1_000_000).contains(startAt), (1...100).contains(limit) else { throw JiraTransportError.invalidRequest }
        var request = try JiraIssueRead.make(identifier: identifier, resource: resource, tokens: tokens, now: now)
        var parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        parts.path += "/comment"
        parts.queryItems = [URLQueryItem(name: "startAt", value: String(startAt)),
                            URLQueryItem(name: "maxResults", value: String(limit)), URLQueryItem(name: "orderBy", value: "created")]
        request.url = parts.url
        return request
    }

    static func decode(_ response: JiraHTTPResponse, expectedStart: Int, requestedLimit: Int,
                       context: RedactionContext, redactor: ContentRedactor) throws -> JiraCommentsPage {
        try JiraResponseStatus.validate(response.status)
        guard (0...1_000_000).contains(expectedStart), (1...100).contains(requestedLimit),
              response.body.count <= 262_144, let text = String(data: response.body, encoding: .utf8) else {
            throw JiraServiceError.invalidResponse
        }
        struct Page: Decodable {
            struct Comment: Decodable { let id: String }
            let startAt: Int
            let maxResults: Int
            let total: Int
            let comments: [Comment]
        }
        let page: Page
        do { page = try JSONDecoder().decode(Page.self, from: response.body) }
        catch { throw JiraServiceError.invalidResponse }
        guard page.startAt == expectedStart, (0...1_000_000).contains(page.total),
              (1...requestedLimit).contains(page.maxResults), page.comments.count <= page.maxResults,
              Set(page.comments.map(\.id)).count == page.comments.count,
              page.comments.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && $0.id.utf8.allSatisfy { (48...57).contains($0) } }) else {
            throw JiraServiceError.invalidResponse
        }
        let next = page.startAt + page.comments.count
        guard next <= page.total || page.comments.isEmpty,
              !page.comments.isEmpty || page.startAt >= page.total else { throw JiraServiceError.invalidResponse }
        return JiraCommentsPage(startAt: page.startAt, total: page.total, nextStartAt: next < page.total ? next : nil,
            content: try redactor.redactJSON(text, in: context))
    }

    static func load(identifier: String, startAt: Int, limit: Int, configuration: JiraConnectionConfiguration,
                     resource: JiraCloudResource, tokens: JiraOAuthTokens, context: RedactionContext,
                     redactor: ContentRedactor, now: Date, transport: JiraHTTPTransport) async throws -> JiraCommentsPage {
        try Task.checkCancellation()
        guard configuration.enabled, context.scope == configuration.scope,
              context.environmentID == configuration.environmentID, redactor.context == context else { throw AuthorizationError.scopeMismatch }
        let response = try await transport.send(make(identifier: identifier, startAt: startAt, limit: limit,
            resource: resource, tokens: tokens, now: now), maximumResponseBytes: 262_144)
        try Task.checkCancellation()
        return try decode(response, expectedStart: startAt, requestedLimit: limit, context: context, redactor: redactor)
    }
}
