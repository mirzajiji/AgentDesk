import AgentDeskCore
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskPlugins

final class JiraOAuthRegistrationBindingTests: XCTestCase {
    func testChangedRegistrationAndLegacyGrantNeverDispatchRefresh() async throws {
        RegistrationBindingProtocol.calls.withLock { $0 = 0 }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let configuration = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
        let store = MemorySecrets(scope: secretScope)
        let vault = try JiraCredentialVault(configuration: configuration, store: store)
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)),
            refreshToken: SecretValue(Data("synthetic-refresh".utf8)), expiresAt: Date(timeIntervalSince1970: 1), scopes: ["read:jira-work"])
        func broker(host: String = "broker.example", client: String = "synthetic", path: String = "/callback",
                    access: JiraOAuthAccess = .readOnly) throws -> JiraOAuthBrokerClient {
            try JiraOAuthBrokerClient(origin: URL(string: "https://" + host)!, clientID: client,
                callback: URL(string: "https://broker.example" + path)!, access: access, protocolClasses: [RegistrationBindingProtocol.self])
        }
        let original = try broker()
        try await vault.save(tokens, registration: original.registrationFingerprint)
        let matching = try await vault.load(registration: original.registrationFingerprint)
        XCTAssertNotNil(matching)
        let adapter = JiraCloudAdapter(store: store, now: { Date() }, makeTransport: {
            try JiraHTTPTransport(origin: $0, protocolClasses: [RegistrationBindingProtocol.self])
        })
        for changed in [try broker(host: "different.example"), try broker(client: "different"),
                        try broker(path: "/different"), try broker(access: .readWrite)] {
            XCTAssertNotEqual(changed.registrationFingerprint, original.registrationFingerprint)
            let login = try JiraOAuthLogin(configuration: configuration, broker: changed, adapter: adapter, store: store)
            do { _ = try await login.refresh(); XCTFail("Foreign registration refreshed a grant") }
            catch { XCTAssertEqual(error as? JiraServiceError, .authenticationRequired) }
            XCTAssertEqual(RegistrationBindingProtocol.calls.withLock { $0 }, 0)
            let retained = try await vault.load(registration: original.registrationFingerprint)
            XCTAssertNotNil(retained, "Rejecting a different registration must not delete the original grant")
            await login.close()
        }
        // Older bundles remain readable for their existing access token, but cannot be sent to a broker.
        try await vault.save(tokens)
        let login = try JiraOAuthLogin(configuration: configuration, broker: original, adapter: adapter, store: store)
        do { _ = try await login.refresh(); XCTFail("Unbound legacy grant refreshed") }
        catch { XCTAssertEqual(error as? JiraServiceError, .authenticationRequired) }
        let retained = try await vault.load()
        XCTAssertNotNil(retained)
        XCTAssertEqual(RegistrationBindingProtocol.calls.withLock { $0 }, 0)
        try await login.logout()
        let removed = try await vault.load()
        XCTAssertNil(removed)
        await login.close()
    }
}

private final class RegistrationBindingProtocol: URLProtocol {
    static let calls = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.withLock { $0 += 1 }
        client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
    }
    override func stopLoading() {}
}
