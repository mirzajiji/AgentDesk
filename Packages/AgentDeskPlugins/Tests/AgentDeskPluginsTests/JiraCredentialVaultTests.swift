import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraCredentialVaultTests: XCTestCase {
    func testRoundTripAndLogoutUseOneScopedSecretBundle() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let reference = SecretReference(scope: secretScope)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: XCTUnwrap(URL(string: "https://jira.example.test")), credential: reference)
        let store = MemorySecrets(scope: secretScope)
        let vault = try JiraCredentialVault(configuration: config, store: store)
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)),
            refreshToken: SecretValue(Data("synthetic-refresh".utf8)), expiresAt: Date(timeIntervalSince1970: 4600), scopes: ["read:jira-user"])
        try await vault.save(tokens)
        let restored = try await vault.load()
        XCTAssertEqual(restored?.expiresAt, tokens.expiresAt)
        XCTAssertEqual(restored?.refreshToken?.withBytes { $0 }, Data("synthetic-refresh".utf8))
        let count = await store.count
        XCTAssertEqual(count, 1)
        let malformed = Data(#"{"connectionID":"CONNECTION","access":"header\r\ninjection","expiresAt":1000,"scopes":["read:jira-user"]}"#.replacingOccurrences(of: "CONNECTION", with: config.id.uuidString).utf8)
        try await store.set(SecretValue(malformed), for: reference)
        do {
            _ = try await vault.load()
            XCTFail("Malformed stored token accepted")
        } catch { XCTAssertEqual(error as? JiraServiceError, .invalidResponse) }
        try await vault.logout()
        let empty = try await vault.load()
        XCTAssertNil(empty)
        let foreign = MemorySecrets(scope: try SecretScope(workspaceID: WorkspaceID()))
        XCTAssertThrowsError(try JiraCredentialVault(configuration: config, store: foreign))
    }
}

actor MemorySecrets: SecretStore {
    nonisolated let scope: SecretScope
    private var values: [SecretReference: SecretValue] = [:]
    init(scope: SecretScope) { self.scope = scope }
    var count: Int { values.count }
    func set(_ value: SecretValue, for reference: SecretReference) throws {
        guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }
        values[reference] = value
    }
    func get(_ reference: SecretReference) throws -> SecretValue? {
        guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }
        return values[reference]
    }
    func delete(_ reference: SecretReference) throws {
        guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }
        values.removeValue(forKey: reference)
    }
    func exists(_ reference: SecretReference) throws -> Bool { try get(reference) != nil }
}
