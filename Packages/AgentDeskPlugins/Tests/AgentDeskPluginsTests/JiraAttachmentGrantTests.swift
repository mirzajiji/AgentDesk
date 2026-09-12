import AgentDeskCore
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskPlugins

final class JiraAttachmentGrantTests: XCTestCase {
    func testDiagnosticsAreScopedRedactedAndRejectMissingGrant() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment, instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
        let vault = try JiraCredentialVault(configuration: config, store: DisappearingGrant(scope: secretScope))
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil, expiresAt: Date().addingTimeInterval(600), scopes: ["read:jira-work"])
        try await vault.save(tokens)
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-work"])
        let transport = try JiraHTTPTransport(origin: resource.apiOrigin, protocolClasses: [GrantProtocol.self])
        let account = try JiraCloudAccount.decode(.init(status: 200, body: Data(#"{"accountId":"synthetic","displayName":"synthetic-access","active":true}"#.utf8)))
        let session = JiraCloudSession(account: account, transport: transport, configuration: config, resource: resource, tokens: tokens, vault: vault, now: { Date() })
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let foreign = RedactionContext(scope: scope, environmentID: EnvironmentID(), runID: RunID())
        do { _ = try await session.diagnostics(context: foreign); XCTFail("Foreign diagnostics accepted") }
        catch { XCTAssertEqual(error as? AuthorizationError, .scopeMismatch) }
        let diagnostics = try await session.diagnostics(context: context)
        XCTAssertEqual(diagnostics.account.text, "[REDACTED]")
        XCTAssertEqual(diagnostics.grantedScopes.text, "read:jira-work")
        XCTAssertEqual(diagnostics.siteScopes.text, "read:jira-work")
        do { _ = try await session.diagnostics(context: context); XCTFail("Missing grant accepted") }
        catch { XCTAssertEqual(error as? PluginConnectionError, .authenticationExpired) }
        await session.close()
        do { _ = try await session.diagnostics(context: context); XCTFail("Closed connection accepted") }
        catch { XCTAssertEqual(error as? JiraTransportError, .closed) }
    }
    func testMissingGrantAfterMetadataPreventsContentRequest() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment, instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
        let vault = try JiraCredentialVault(configuration: config, store: DisappearingGrant(scope: secretScope))
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil, expiresAt: Date().addingTimeInterval(600), scopes: ["read:jira-work"])
        try await vault.save(tokens)
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-work"])
        let transport = try JiraHTTPTransport(origin: resource.apiOrigin, protocolClasses: [GrantProtocol.self])
        let account = try JiraCloudAccount.decode(.init(status: 200, body: Data(#"{"accountId":"synthetic","displayName":"Synthetic","active":true}"#.utf8)))
        let session = JiraCloudSession(account: account, transport: transport, configuration: config, resource: resource, tokens: tokens, vault: vault, now: { Date() })
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(.attachmentsRead, .allow)])
        let operation = JiraReadOperation.attachmentContent(id: "123", expectedSize: 4, maximumBytes: 4)
        let prepared = try await session.prepare(operation, configurationRevision: 1, permissions: permissions, runID: context.runID)
        do {
            _ = try await session.executePrepared(operation, prepared: prepared, permissions: permissions, context: context, redactor: ContentRedactor(context: context))
            XCTFail("Content downloaded after credential disappeared")
        } catch { XCTAssertEqual(error as? PluginConnectionError, .authenticationExpired) }
        let paths = GrantProtocol.paths.withLock { $0.filter { $0.hasPrefix(resource.apiOrigin.path + "/") } }
        XCTAssertEqual(paths, [resource.apiOrigin.path + "/rest/api/3/attachment/123"])
        await session.close()
        GrantProtocol.paths.withLock { $0.removeAll { $0.hasPrefix(resource.apiOrigin.path + "/") } }
    }
}
private actor DisappearingGrant: SecretStore {
    nonisolated let scope: SecretScope
    private var secret: SecretValue?
    private var reads = 0
    init(scope: SecretScope) { self.scope = scope }
    func set(_ value: SecretValue, for reference: SecretReference) throws { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; secret = value }
    func get(_ reference: SecretReference) throws -> SecretValue? {
        guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }
        reads += 1
        if reads > 1 { secret = nil }
        return secret
    }
    func delete(_ reference: SecretReference) throws { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; secret = nil }
    func exists(_ reference: SecretReference) throws -> Bool { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; return secret != nil }
}
private final class GrantProtocol: URLProtocol {
    static let paths = Mutex<[String]>([])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.paths.withLock { $0.append(url.path) }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = url.path.contains("/content/") ? "test" : #"{"id":"123","filename":"evidence.txt","size":4,"mimeType":"text/plain"}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
