import AgentDeskCore
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskPlugins

final class JiraOAuthRotationTests: XCTestCase {
    func testChangedConfigurationCannotConsumeOrRetainRotatedGrant() async throws {
        for failedCheck in 1...4 {
            let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
            let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
            let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
                instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
            let store = RotationSecrets(scope: secretScope)
            let vault = try JiraCredentialVault(configuration: config, store: store)
            let broker = try JiraOAuthBrokerClient(origin: URL(string: "https://broker.example")!, clientID: "synthetic-client",
                callback: URL(string: "https://broker.example/callback")!, protocolClasses: [NativeBrokerProtocol.self])
            try await vault.save(JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-old".utf8)),
                refreshToken: SecretValue(Data("synthetic-refresh".utf8)), expiresAt: Date(timeIntervalSince1970: 1),
                scopes: ["read:jira-user", "read:jira-work"]), registration: broker.registrationFingerprint)
            await store.clearEvents()
            let adapter = JiraCloudAdapter(store: store, now: { Date() }, makeTransport: {
                try JiraHTTPTransport(origin: $0, protocolClasses: [AdapterProtocol.self])
            })
            let login = try JiraOAuthLogin(configuration: config, broker: broker, adapter: adapter, store: store)
            let checks = Mutex(0)
            do {
                _ = try await login.refresh(validateConfiguration: {
                    let count = checks.withLock { $0 += 1; return $0 }
                    if count == failedCheck { throw PluginStorageError.staleRevision }
                })
                XCTFail("Stale configuration accepted rotation")
            } catch { XCTAssertEqual(error as? PluginStorageError, .staleRevision) }
            let events = await store.events
            let expected = [[], ["get"], ["get", "delete"], ["get", "delete", "set", "delete"]]
            XCTAssertEqual(events, expected[failedCheck - 1])
            let remaining = try await vault.load()
            XCTAssertEqual(remaining != nil, failedCheck <= 2)
            await login.close()
        }
    }

    func testRefreshConsumesOldGrantBeforeReplacementAndFailureCannotRetry() async throws {
        for succeeds in [true, false] {
            let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
            let environment = EnvironmentID()
            let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
            let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
                instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
            let store = RotationSecrets(scope: secretScope)
            let vault = try JiraCredentialVault(configuration: config, store: store)
            let host = succeeds ? "broker.example" : "refresh-failed.example"
            let broker = try JiraOAuthBrokerClient(origin: URL(string: "https://" + host)!, clientID: "synthetic-client",
                callback: URL(string: "https://broker.example/callback")!, protocolClasses: [NativeBrokerProtocol.self])
            try await vault.save(JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-old-access".utf8)),
                refreshToken: SecretValue(Data("synthetic-old-refresh".utf8)), expiresAt: Date(timeIntervalSince1970: 1),
                scopes: ["read:jira-user", "read:jira-work"]), registration: broker.registrationFingerprint)
            await store.clearEvents()
            let adapter = JiraCloudAdapter(store: store, now: { Date() }, makeTransport: {
                try JiraHTTPTransport(origin: $0, protocolClasses: [AdapterProtocol.self])
            })
            let login = try JiraOAuthLogin(configuration: config, broker: broker, adapter: adapter, store: store)
            do {
                let account = try await login.refresh()
                XCTAssertTrue(succeeds)
                XCTAssertEqual(account.accountID, "synthetic-account")
            } catch { XCTAssertFalse(succeeds) }
            let events = await store.events
            XCTAssertEqual(events, succeeds ? ["get", "delete", "set"] : ["get", "delete"])
            if succeeds {
                let rebound = try await vault.load(registration: broker.registrationFingerprint)
                XCTAssertNotNil(rebound, "Rotated grant lost its registration binding")
            }
            if !succeeds {
                do { _ = try await login.refresh(); XCTFail("Consumed token retried") }
                catch { XCTAssertEqual(error as? JiraServiceError, .authenticationRequired) }
            }
            try await login.logout()
            let remaining = try await vault.load()
            XCTAssertNil(remaining)
            await broker.close()
        }
    }
}
private actor RotationSecrets: SecretStore {
    nonisolated let scope: SecretScope
    private var value: SecretValue?
    private(set) var events: [String] = []
    init(scope: SecretScope) { self.scope = scope }
    func clearEvents() { events.removeAll() }
    func set(_ value: SecretValue, for reference: SecretReference) { events.append("set"); self.value = value }
    func get(_ reference: SecretReference) -> SecretValue? { events.append("get"); return value }
    func delete(_ reference: SecretReference) { events.append("delete"); value = nil }
    func exists(_ reference: SecretReference) -> Bool { value != nil }
}
