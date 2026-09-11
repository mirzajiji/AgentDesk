import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// Writes one secret bundle so a rotating refresh token is never split across separate saves.
actor JiraCredentialVault {
    private let store: any SecretStore
    private let reference: SecretReference
    private let connectionID: UUID
    private var busy = false

    init(configuration: JiraConnectionConfiguration, store: any SecretStore) throws {
        guard let reference = configuration.credential, reference.scope == store.scope else {
            throw PluginConfigurationError.credentialScopeMismatch
        }
        self.reference = reference; self.connectionID = configuration.id; self.store = store
    }

    func save(_ tokens: JiraOAuthTokens, registration: ActionFingerprint? = nil) async throws {
        try begin(); defer { busy = false }
        let record = Stored(connectionID: connectionID,
            access: tokens.accessToken.withBytes { String(decoding: $0, as: UTF8.self) },
            refresh: tokens.refreshToken?.withBytes { String(decoding: $0, as: UTF8.self) },
            expiresAt: tokens.expiresAt, scopes: tokens.scopes, registration: registration)
        let bytes = try JSONEncoder().encode(record)
        try await store.set(SecretValue(bytes), for: reference)
    }

    func load(registration: ActionFingerprint? = nil) async throws -> JiraOAuthTokens? {
        try begin(); defer { busy = false }
        guard let secret = try await store.get(reference) else { return nil }
        let record: Stored
        do { record = try secret.withBytes { try JSONDecoder().decode(Stored.self, from: $0) } }
        catch { throw JiraServiceError.invalidResponse }
        guard record.connectionID == connectionID, record.expiresAt.timeIntervalSince1970.isFinite,
              !record.access.isEmpty, !record.scopes.isEmpty else { throw JiraServiceError.invalidResponse }
        if let registration, record.registration != registration { throw JiraServiceError.authenticationRequired }
        return try JiraOAuthTokens(accessToken: SecretValue(Data(record.access.utf8)),
            refreshToken: record.refresh.map { try SecretValue(Data($0.utf8)) },
            expiresAt: record.expiresAt, scopes: record.scopes)
    }

    func logout() async throws {
        try begin(); defer { busy = false }
        try await store.delete(reference)
    }

    private func begin() throws {
        try Task.checkCancellation()
        guard !busy else { throw JiraServiceError.unavailable }
        busy = true
    }
    private struct Stored: Codable {
        let connectionID: UUID
        let access: String
        let refresh: String?
        let expiresAt: Date
        let scopes: Set<String>
        let registration: ActionFingerprint?
    }
}
