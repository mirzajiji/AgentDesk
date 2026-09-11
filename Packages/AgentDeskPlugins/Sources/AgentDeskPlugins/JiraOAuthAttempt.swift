import AgentDeskCore
import AgentDeskSecurity
import Foundation

public enum JiraOAuthError: Error, Equatable, Sendable {
    case invalidConfiguration, invalidCallback, expired, alreadyUsed, denied, credentialCleanupFailed
}

/// One scoped browser authorization attempt. Token exchange is a separate trusted boundary.
actor JiraOAuthAttempt {
    let scope: ProjectScope
    let connectionID: UUID
    let authorizationURL: URL
    private let callback: URL
    private let state: String
    private let expiresAt: Date
    private var lastObserved: Date
    private var used = false

    init(scope: ProjectScope, connectionID: UUID, clientID: String, callback: URL,
         scopes: [String], now: Date = Date()) throws {
        guard !clientID.isEmpty, clientID.utf8.count <= 256,
              callback.scheme == "https", callback.host != nil, callback.user == nil, callback.password == nil,
              callback.query == nil, callback.fragment == nil,
              !scopes.isEmpty, scopes.count <= 32, Set(scopes).count == scopes.count,
              scopes.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 100 && !$0.contains(where: { $0.isWhitespace }) }),
              now.timeIntervalSince1970.isFinite else { throw JiraOAuthError.invalidConfiguration }
        self.scope = scope; self.connectionID = connectionID; self.callback = callback
        state = UUID().uuidString + UUID().uuidString
        expiresAt = now.addingTimeInterval(600)
        lastObserved = now
        var url = URLComponents(string: "https://auth.atlassian.com/authorize")!
        url.queryItems = [URLQueryItem(name: "audience", value: "api.atlassian.com"),
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "scope", value: scopes.joined(separator: " ")),
            URLQueryItem(name: "redirect_uri", value: callback.absoluteString), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "response_type", value: "code"), URLQueryItem(name: "prompt", value: "consent")]
        guard let authorizationURL = url.url else { throw JiraOAuthError.invalidConfiguration }
        self.authorizationURL = authorizationURL
    }

    func consume(_ url: URL, in requested: ProjectScope, connectionID requestedConnection: UUID,
                 now: Date = Date()) throws -> SecretValue {
        guard !used else { throw JiraOAuthError.alreadyUsed }
        guard now.timeIntervalSince1970.isFinite, now >= lastObserved, now < expiresAt else {
            used = true
            throw JiraOAuthError.expired
        }
        lastObserved = now
        guard requested == scope, requestedConnection == connectionID,
              url.scheme == callback.scheme, url.host == callback.host, url.port == callback.port,
              url.path == callback.path, url.user == nil, url.password == nil, url.fragment == nil,
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.count <= 8, Set(items.map(\.name)).count == items.count,
              items.first(where: { $0.name == "state" })?.value == state else { throw JiraOAuthError.invalidCallback }
        if items.contains(where: { $0.name == "error" }) {
            used = true
            throw JiraOAuthError.denied
        }
        guard let code = items.first(where: { $0.name == "code" })?.value,
              !code.isEmpty, code.utf8.count <= 8192,
              !code.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw JiraOAuthError.invalidCallback
        }
        used = true
        return try SecretValue(Data(code.utf8))
    }
}
