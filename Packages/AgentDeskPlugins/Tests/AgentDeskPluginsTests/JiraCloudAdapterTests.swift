import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraCloudAdapterTests: XCTestCase {
    func testDiscoveryRequiresBothGrantsAndNeverAdvertisesMutations() {
        let read: Set<String> = ["read:jira-work"]
        XCTAssertEqual(JiraCloudSession.readCapabilities(tokenScopes: read, siteScopes: read), [.issuesRead, .commentsRead, .attachmentsRead])
        XCTAssertTrue(JiraCloudSession.readCapabilities(tokenScopes: [], siteScopes: read).isEmpty)
        XCTAssertTrue(JiraCloudSession.readCapabilities(tokenScopes: read, siteScopes: []).isEmpty)
        XCTAssertTrue(JiraCloudSession.readCapabilities(tokenScopes: ["write:jira-work"], siteScopes: ["write:jira-work"]).isEmpty)
    }
    func testLifecycleValidatesAccountAndMissingCredentialsExpireConnection() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let configuration = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
        let store = MemorySecrets(scope: secretScope)
        let vault = try JiraCredentialVault(configuration: configuration, store: store)
        let adapter = JiraCloudAdapter(store: store, now: { Date(timeIntervalSince1970: 1000) },
            makeTransport: { try JiraHTTPTransport(origin: $0, protocolClasses: [AdapterProtocol.self]) })
        let lifecycle = PluginConnectionLifecycle(scope: scope, environmentID: environment)
        try await lifecycle.configure(configuration)
        do {
            try await lifecycle.connect(using: adapter)
            XCTFail("Missing credentials accepted")
        } catch { XCTAssertEqual(error as? PluginConnectionError, .authenticationExpired) }
        let expired = await lifecycle.state
        XCTAssertEqual(expired, .authenticationExpired)
        try await vault.save(JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 2000), scopes: ["read:jira-user", "read:jira-work"]))
        try await lifecycle.connect(using: adapter)
        let connected = await lifecycle.state
        XCTAssertEqual(connected, .connected)
        let capabilities = await lifecycle.capabilities
        XCTAssertEqual(capabilities, [.issuesRead, .commentsRead, .attachmentsRead])
        let raw = try await adapter.connect(configuration)
        let session = try XCTUnwrap(raw as? JiraCloudSession)
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let permissions = try PluginPermissions(connectionID: configuration.id, scope: scope, environmentID: environment,
            rules: [.init(.issuesRead, .allow)])
        let prepared = try await session.prepare(.issue(identifier: "A-1"), configurationRevision: 1, permissions: permissions, runID: context.runID)
        let redactor = try ContentRedactor(context: context)
        let result = try await session.executePrepared(.issue(identifier: "A-1"), prepared: prepared, permissions: permissions, context: context, redactor: redactor)
        guard case .json(let evidence) = result else { return XCTFail("Expected issue evidence") }
        XCTAssertFalse(evidence.text.contains("synthetic-access"))
        XCTAssertTrue(evidence.text.contains("[REDACTED]"))
        do {
            _ = try await session.executePrepared(.issue(identifier: "A-2"), prepared: prepared, permissions: permissions, context: context, redactor: redactor)
            XCTFail("Changed target executed")
        } catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        await lifecycle.disconnect()
        let disconnected = await lifecycle.state
        XCTAssertEqual(disconnected, .disconnected)
        try await vault.logout()
        do {
            _ = try await session.executePrepared(.issue(identifier: "A-1"), prepared: prepared, permissions: permissions, context: context, redactor: redactor)
            XCTFail("Session used a deleted grant")
        } catch { XCTAssertEqual(error as? PluginConnectionError, .authenticationExpired) }
        await session.close()
        do {
            try await lifecycle.connect(using: adapter)
            XCTFail("Logged-out credentials reused")
        } catch { XCTAssertEqual(error as? PluginConnectionError, .authenticationExpired) }
    }
}

private final class AdapterProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let authorized = request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access"
        let discovery = request.url?.path == "/oauth/token/accessible-resources"
        let issue = request.url?.path.hasSuffix("/issue/A-1") == true
        let body = issue ? #"{"id":"123","key":"A-1","fields":{"summary":"Synthetic issue synthetic-access"}}"# : discovery
            ? #"[{"id":"12345678-1234-1234-1234-123456789012","url":"https://synthetic.atlassian.net","scopes":["read:jira-user","read:jira-work"]}]"#
            : #"{"accountId":"synthetic-account","displayName":"Synthetic User","active":true}"#
        let validPath = issue || discovery || request.url?.path == "/ex/jira/12345678-1234-1234-1234-123456789012/rest/api/3/myself"
        let response = HTTPURLResponse(url: request.url!, statusCode: authorized && validPath ? 200 : 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
