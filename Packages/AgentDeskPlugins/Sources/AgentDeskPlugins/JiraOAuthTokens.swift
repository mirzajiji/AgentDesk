import AgentDeskSecurity
import Foundation

/// Token values deliberately cannot be serialized as ordinary configuration.
struct JiraOAuthTokens: Sendable {
    let accessToken: SecretValue
    let refreshToken: SecretValue?
    let expiresAt: Date
    let scopes: Set<String>

    init(accessToken: SecretValue, refreshToken: SecretValue?, expiresAt: Date, scopes: Set<String>) throws {
        func valid(_ value: SecretValue) -> Bool {
            value.withBytes { !$0.isEmpty && $0.count <= 32_768 && $0.allSatisfy { $0 > 32 && $0 < 127 } }
        }
        guard valid(accessToken), refreshToken.map(valid) ?? true,
              expiresAt.timeIntervalSince1970.isFinite, !scopes.isEmpty, scopes.count <= 64,
              scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 100 && $0.utf8.allSatisfy { $0 > 32 && $0 < 127 } }) else {
            throw JiraServiceError.invalidResponse
        }
        self.accessToken = accessToken; self.refreshToken = refreshToken
        self.expiresAt = expiresAt; self.scopes = scopes
    }

    static func decode(_ response: JiraHTTPResponse, now: Date) throws -> JiraOAuthTokens {
        try JiraResponseStatus.validate(response.status)
        struct Payload: Decodable {
            let access_token: String
            let refresh_token: String?
            let expires_in: Double
            let scope: String
            let token_type: String?
        }
        let payload: Payload
        do { payload = try JSONDecoder().decode(Payload.self, from: response.body) }
        catch { throw JiraServiceError.invalidResponse }
        guard now.timeIntervalSince1970.isFinite,
              payload.expires_in.isFinite, payload.expires_in > 0, payload.expires_in <= 604_800,
              payload.token_type == nil || payload.token_type?.lowercased() == "bearer",
              !payload.access_token.isEmpty, payload.access_token.utf8.count <= 32_768,
              payload.access_token.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }),
              payload.scope.utf8.count <= 8192 else { throw JiraServiceError.invalidResponse }
        let refresh: SecretValue?
        if let value = payload.refresh_token {
            guard !value.isEmpty, value.utf8.count <= 32_768,
                  value.unicodeScalars.allSatisfy({ $0.value > 32 && $0.value < 127 }) else { throw JiraServiceError.invalidResponse }
            refresh = try SecretValue(Data(value.utf8))
        } else { refresh = nil }
        let scopes = Set(payload.scope.split(separator: " ").map(String.init))
        guard !scopes.isEmpty, scopes.count <= 64,
              scopes.allSatisfy({ $0.utf8.count <= 100 && !$0.contains(where: { $0.isWhitespace }) }) else {
            throw JiraServiceError.invalidResponse
        }
        return try JiraOAuthTokens(accessToken: try SecretValue(Data(payload.access_token.utf8)), refreshToken: refresh,
            expiresAt: now.addingTimeInterval(payload.expires_in), scopes: scopes)
    }
}
