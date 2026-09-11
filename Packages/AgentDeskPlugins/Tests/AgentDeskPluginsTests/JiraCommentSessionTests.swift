import AgentDeskCore
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskPlugins

final class JiraCommentSessionTests: XCTestCase {
    func testExactDraftChecksPrecedeTransportAndTransportFailureIsUnknown() async throws {
        CommentSessionProtocol.calls.withLock { $0 = 0 }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
        let vault = try JiraCredentialVault(configuration: config, store: MemorySecrets(scope: secretScope))
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 2000), scopes: ["write:jira-work", "read:jira-work"])
        try await vault.save(tokens)
        let resource = JiraCloudResource(id: UUID(), scopes: ["write:jira-work", "read:jira-work"])
        let transport = try JiraHTTPTransport(origin: resource.apiOrigin, protocolClasses: [CommentSessionProtocol.self])
        let session = JiraCloudSession(account: .init(accountID: "synthetic", displayName: "Synthetic"), transport: transport,
            configuration: config, resource: resource, tokens: tokens, vault: vault, now: { Date(timeIntervalSince1970: 1000) })
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(.commentsWrite, .approval), .init(.commentsRead, .approval)])
        let draft = try JiraCommentDraft(identifier: "A-1", content: redactor.redactText("Evidence", in: context))
        let prepared = try await session.prepareComment(draft, configurationRevision: 1, permissions: permissions, runID: context.runID)
        let changed = try JiraCommentDraft(identifier: "A-1", content: redactor.redactText("Changed", in: context))
        do { _ = try await session.executeComment(changed, prepared: prepared, permissions: permissions, redactor: redactor); XCTFail("Changed draft sent") }
        catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        let sensitive = try JiraCommentDraft(identifier: "A-1", content: redactor.redactText("Echo synthetic-access", in: context))
        let sensitiveAction = try await session.prepareComment(sensitive, configurationRevision: 1, permissions: permissions, runID: context.runID)
        do { _ = try await session.executeComment(sensitive, prepared: sensitiveAction, permissions: permissions, redactor: redactor); XCTFail("Credential sent") }
        catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        XCTAssertEqual(CommentSessionProtocol.calls.withLock { $0 }, 0)
        do {
            _ = try await session.executeComment(draft, prepared: prepared, permissions: permissions, redactor: redactor,
                beforeDispatch: { throw BugRegistryError.staleRevision })
            XCTFail("Stale evidence dispatched")
        } catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
        XCTAssertEqual(CommentSessionProtocol.calls.withLock { $0 }, 0)
        do {
            _ = try await session.executeComment(draft, prepared: prepared, permissions: permissions, redactor: redactor,
                beforeDispatch: { try await vault.logout() })
            XCTFail("Grant removed during evidence validation was used")
        } catch { XCTAssertEqual(error as? PluginConnectionError, .authenticationExpired) }
        XCTAssertEqual(CommentSessionProtocol.calls.withLock { $0 }, 0)
        try await vault.save(tokens)
        let receipt = try await session.executeComment(draft, prepared: prepared, permissions: permissions, redactor: redactor)
        XCTAssertEqual(receipt.id, "123")
        let read = try await session.prepare(.comments(identifier: "A-1", startAt: 0, limit: 20), configurationRevision: 1,
            permissions: permissions, runID: context.runID)
        do {
            _ = try await session.reconcileComment(draft, startAt: 20, limit: 20, preparedRead: read, permissions: permissions, redactor: redactor)
            XCTFail("Unapproved page used for reconciliation")
        } catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        let foreign = try JiraCommentDraft(identifier: "A-2", content: draft.content)
        do {
            _ = try await session.reconcileComment(foreign, startAt: 0, limit: 20, preparedRead: read, permissions: permissions, redactor: redactor)
            XCTFail("Another issue used for reconciliation")
        } catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        XCTAssertEqual(CommentSessionProtocol.calls.withLock { $0 }, 1)
        let candidates = try await session.reconcileComment(draft, startAt: 0, limit: 20, preparedRead: read, permissions: permissions, redactor: redactor)
        XCTAssertEqual(candidates.matchingIDs, ["123"])
        XCTAssertNil(candidates.nextStartAt)
        let failing = try JiraCommentDraft(identifier: "A-2", content: draft.content)
        let failingAction = try await session.prepareComment(failing, configurationRevision: 1, permissions: permissions, runID: context.runID)
        do { _ = try await session.executeComment(failing, prepared: failingAction, permissions: permissions, redactor: redactor); XCTFail("Transport failure succeeded") }
        catch { XCTAssertEqual(error as? JiraMutationError, .outcomeUnknown) }
        XCTAssertEqual(CommentSessionProtocol.calls.withLock { $0 }, 3)
        await session.close()
    }
}
private final class CommentSessionProtocol: URLProtocol {
    static let calls = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.withLock { $0 += 1 }
        if request.httpMethod == "GET" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"startAt":0,"maxResults":20,"total":1,"comments":[{"id":"123","body":{"type":"doc","version":1,"content":[{"type":"paragraph","content":[{"type":"text","text":"Evidence"}]}]}}]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        if request.url!.path.contains("A-2") {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost)); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 201, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"123"}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
