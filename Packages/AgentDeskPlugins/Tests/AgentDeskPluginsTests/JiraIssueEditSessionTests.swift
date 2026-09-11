import AgentDeskCore
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskPlugins

final class JiraIssueEditSessionTests: XCTestCase {
    func testChangedOrStaleSnapshotPreventsWriteAndAcknowledgmentIsReturned() async throws {
        EditSessionProtocol.calls.withLock { $0 = 0 }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
        let vault = try JiraCredentialVault(configuration: config, store: MemorySecrets(scope: secretScope))
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 2000), scopes: ["write:jira-work", "read:jira-work"])
        try await vault.save(tokens)
        let resource = JiraCloudResource(id: UUID(), scopes: ["write:jira-work", "read:jira-work"])
        let transport = try JiraHTTPTransport(origin: resource.apiOrigin, protocolClasses: [EditSessionProtocol.self])
        let session = JiraCloudSession(account: .init(accountID: "synthetic", displayName: "Synthetic"), transport: transport,
            configuration: config, resource: resource, tokens: tokens, vault: vault, now: { Date(timeIntervalSince1970: 1000) })
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(.issuesUpdate, .approval), .init(.issuesRead, .approval)])
        let read = try await session.prepare(.issue(identifier: "A-1"), configurationRevision: 1, permissions: permissions, runID: context.runID)
        let snapshot = try await session.executeIssueSnapshot(identifier: "A-1", prepared: read, permissions: permissions, context: context, redactor: redactor)
        let draft = try snapshot.edit(summary: redactor.redactText("After", in: context))
        let prepared = try await session.prepareIssueEdit(draft, configurationRevision: 1, permissions: permissions, runID: context.runID)
        let changed = try JiraIssueEditDraft(identifier: "A-1", summary: draft.summary, expectedIssue: .canonical("different state"))
        let changedAction = try await session.prepareIssueEdit(changed, configurationRevision: 1, permissions: permissions, runID: context.runID)
        do {
            _ = try await session.executeIssueEdit(changed, prepared: changedAction, permissions: permissions, redactor: redactor,
                readCurrent: { snapshot }, beforeDispatch: {})
            XCTFail("Changed baseline dispatched")
        } catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        do {
            _ = try await session.executeIssueEdit(draft, prepared: prepared, permissions: permissions, redactor: redactor,
                readCurrent: { snapshot }, beforeDispatch: { throw AuthorizationError.denied })
            XCTFail("Revoked authority dispatched")
        } catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        XCTAssertEqual(EditSessionProtocol.calls.withLock { $0 }, 1)
        let receipt = try await session.executeIssueEdit(draft, prepared: prepared, permissions: permissions, redactor: redactor,
            readCurrent: { try await session.executeIssueSnapshot(identifier: "A-1", prepared: read, permissions: permissions, context: context, redactor: redactor) },
            beforeDispatch: {})
        XCTAssertEqual(receipt.identifier, "A-1")
        XCTAssertEqual(EditSessionProtocol.calls.withLock { $0 }, 3)
        await session.close()
    }
}
private final class EditSessionProtocol: URLProtocol {
    static let calls = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.withLock { $0 += 1 }
        let reading = request.httpMethod == "GET"
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: reading ? 200 : 204,
            httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        if reading {
            client?.urlProtocol(self, didLoad: Data(#"{"id":"123","key":"A-1","fields":{"updated":"2026-09-11T12:00:00Z","summary":"Before"}}"#.utf8))
        }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
