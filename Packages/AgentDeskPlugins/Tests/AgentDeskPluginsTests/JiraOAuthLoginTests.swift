import AgentDeskCore
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskPlugins

final class JiraOAuthLoginTests: XCTestCase {
    func testConfigurationChangeDuringSignInRejectsAndCleansSavedGrant() async throws {
        for failingCheck in [1, 2, 3] {
            let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
            let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
            let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
                instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
            let store = MemorySecrets(scope: secretScope)
            let broker = try JiraOAuthBrokerClient(origin: URL(string: "https://broker.example")!, clientID: "synthetic-client",
                callback: URL(string: "https://broker.example/callback")!, protocolClasses: [NativeBrokerProtocol.self])
            let adapter = JiraCloudAdapter(store: store, now: { Date() }, makeTransport: {
                try JiraHTTPTransport(origin: $0, protocolClasses: [AdapterProtocol.self])
            })
            let login = try JiraOAuthLogin(configuration: config, broker: broker, adapter: adapter, store: store)
            let checks = Mutex(0), browserCalls = Mutex(0)
            do {
                _ = try await login.signIn(validateConfiguration: {
                    let count = checks.withLock { $0 += 1; return $0 }
                    if count == failingCheck { throw PluginStorageError.staleRevision }
                }, openBrowser: { _ in browserCalls.withLock { $0 += 1 } })
                XCTFail("Changed configuration accepted a sign-in")
            } catch { XCTAssertEqual(error as? PluginStorageError, .staleRevision) }
            XCTAssertEqual(checks.withLock { $0 }, failingCheck)
            XCTAssertEqual(browserCalls.withLock { $0 }, failingCheck == 1 ? 0 : 1)
            let remaining = await store.count
            XCTAssertEqual(remaining, 0, "A rejected sign-in left a grant behind")
            await login.close()
        }
    }

    func testOnlyValidatedSiteGrantIsSavedAndLogoutDeletesIt() async throws {
        for allowed in [true, false] {
            let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
            let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
            let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
                instance: URL(string: allowed ? "https://synthetic.atlassian.net" : "https://foreign.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
            let store = MemorySecrets(scope: secretScope)
            let broker = try JiraOAuthBrokerClient(origin: URL(string: "https://broker.example")!, clientID: "synthetic-client",
                callback: URL(string: "https://broker.example/callback")!, protocolClasses: [NativeBrokerProtocol.self])
            let adapter = JiraCloudAdapter(store: store, now: { Date() }, makeTransport: { try JiraHTTPTransport(origin: $0, protocolClasses: [AdapterProtocol.self]) })
            let login = try JiraOAuthLogin(configuration: config, broker: broker, adapter: adapter, store: store)
            do {
                let account = try await login.signIn { url in XCTAssertEqual(url.host, "auth.atlassian.com") }
                XCTAssertTrue(allowed, "Foreign site grant accepted")
                XCTAssertEqual(account.accountID, "synthetic-account")
            } catch {
                XCTAssertFalse(allowed)
                XCTAssertEqual(error as? JiraServiceError, .accessDenied)
            }
            let count = await store.count
            XCTAssertEqual(count, allowed ? 1 : 0)
            if allowed {
                let vault = try JiraCredentialVault(configuration: config, store: store)
                let bound = try await vault.load(registration: broker.registrationFingerprint)
                XCTAssertNotNil(bound, "New sign-in did not bind its grant")
            }
            await login.close()
            let afterClose = await store.count
            XCTAssertEqual(afterClose, count, "Transport disposal must preserve an established grant")
            do { _ = try await login.signIn { _ in XCTFail("Closed login opened browser") }; XCTFail("Closed login accepted") }
            catch { XCTAssertEqual(error as? JiraServiceError, .unavailable) }
            do { _ = try await login.refresh(); XCTFail("Closed refresh accepted") }
            catch { XCTAssertEqual(error as? JiraServiceError, .unavailable) }
            try await login.logout()
            let afterLogout = await store.count
            XCTAssertEqual(afterLogout, 0)
            await broker.close()
        }
    }
}
