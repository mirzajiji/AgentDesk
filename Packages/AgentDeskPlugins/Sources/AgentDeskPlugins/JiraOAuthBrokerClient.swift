import AgentDeskSecurity
import Foundation

struct JiraBrokerAttempt: Sendable {
    let id: UUID
    let authorizationURL: URL
}

/// Native client knows only public registration values; the confidential secret stays on the broker.
actor JiraOAuthBrokerClient {
    private let origin: URL
    private let clientID: String
    private let callback: URL
    private let transport: JiraHTTPTransport
    init(origin: URL, clientID: String, callback: URL, protocolClasses: [URLProtocol.Type] = []) throws {
        guard !clientID.isEmpty, clientID.utf8.count <= 256, callback.scheme == "https", callback.host != nil,
              callback.user == nil, callback.password == nil, callback.query == nil, callback.fragment == nil else { throw JiraOAuthError.invalidConfiguration }
        self.origin = origin; self.clientID = clientID; self.callback = callback
        transport = try JiraHTTPTransport(origin: origin, maximumBytes: 65_536, protocolClasses: protocolClasses)
    }
    func start(proof: JiraOAuthClaimProof) async throws -> JiraBrokerAttempt {
        let response = try await send(path: "v1/attempts", body: ["challenge": proof.challenge])
        try JiraResponseStatus.validate(response.status)
        guard response.status == 201 else { throw JiraServiceError.invalidResponse }
        struct Result: Decodable { let id: UUID; let authorizationURL: URL }
        let result: Result
        do { result = try JSONDecoder().decode(Result.self, from: response.body) }
        catch { throw JiraServiceError.invalidResponse }
        guard let parts = URLComponents(url: result.authorizationURL, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host == "auth.atlassian.com", parts.port == nil,
              parts.user == nil, parts.password == nil, parts.fragment == nil, parts.path == "/authorize",
              let query = parts.queryItems, query.count == 7, Set(query.map(\.name)).count == 7 else { throw JiraServiceError.invalidResponse }
        let values = Dictionary(uniqueKeysWithValues: query.map { ($0.name, $0.value ?? "") })
        guard values["client_id"] == clientID, values["redirect_uri"] == callback.absoluteString,
              values["audience"] == "api.atlassian.com", values["response_type"] == "code", values["prompt"] == "consent",
              values["scope"] == "read:jira-user read:jira-work offline_access",
              let state = values["state"], state.utf8.count == 43,
              state.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) else { throw JiraServiceError.invalidResponse }
        return JiraBrokerAttempt(id: result.id, authorizationURL: result.authorizationURL)
    }
    func claim(_ attempt: JiraBrokerAttempt, proof: JiraOAuthClaimProof, now: Date) async throws -> JiraOAuthTokens? {
        let response = try await send(path: "v1/attempts/\(attempt.id.uuidString)/claim", body: ["verifier": proof.verifier.withBytes { String(decoding: $0, as: UTF8.self) }])
        if response.status == 202 { return nil }
        if response.status == 403 { throw JiraOAuthError.denied }
        if response.status == 410 { throw JiraOAuthError.expired }
        return try JiraOAuthTokens.decode(response, now: now)
    }
    func cancel(_ attempt: JiraBrokerAttempt, proof: JiraOAuthClaimProof) async throws {
        let response = try await send(path: "v1/attempts/\(attempt.id.uuidString)/cancel", body: ["verifier": proof.verifier.withBytes { String(decoding: $0, as: UTF8.self) }])
        guard response.status == 204 || response.status == 410 else { throw JiraServiceError.invalidResponse }
    }
    func refresh(_ token: SecretValue, now: Date) async throws -> JiraOAuthTokens {
        let value = try token.withBytes { data in
            guard data.count <= 32_768, data.allSatisfy({ $0 > 32 && $0 < 127 }) else {
                throw JiraServiceError.invalidResponse
            }
            return String(decoding: data, as: UTF8.self)
        }
        let response = try await send(path: "v1/refresh", body: ["refresh_token": value])
        let tokens = try JiraOAuthTokens.decode(response, now: now)
        guard tokens.refreshToken != nil else { throw JiraServiceError.invalidResponse }
        return tokens
    }
    func close() async { await transport.close() }
    private func send(path: String, body: [String: String]) async throws -> JiraHTTPResponse {
        var request = URLRequest(url: origin.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await transport.send(request)
    }
}
