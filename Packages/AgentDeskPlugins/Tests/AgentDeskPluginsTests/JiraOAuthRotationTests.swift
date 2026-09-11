import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraOAuthRotationTests: XCTestCase {
    func testRefreshConsumesOldGrantBeforeReplacementAndFailureCannotRetry() async throws {
        for succeeds in [true, false] {
            let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
            let environment = EnvironmentID()
            let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
            let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
                instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
            let store = RotationSecrets(scope: secretScope)
            let vault = try JiraCredentialVault(configuration: config, store: store)
            try await vault.save(JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-old-access".utf8)),
                refreshToken: SecretValue(Data("synthetic-old-refresh".utf8)), expiresAt: Date(timeIntervalSince1970: 1),
                scopes: ["read:jira-user", "read:jira-work"]))
            await store.clearEvents()
            let host = succeeds ? "broker.example" : "refresh-failed.example"
            let broker = try JiraOAuthBrokerClient(origin: URL(string: "https://" + host)!, clientID: "synthetic-client",
                callback: URL(string: "https://broker.example/callback")!, protocolClasses: [NativeBrokerProtocol.self])
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
