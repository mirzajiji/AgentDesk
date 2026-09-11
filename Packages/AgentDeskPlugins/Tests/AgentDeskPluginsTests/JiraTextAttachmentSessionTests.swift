import AgentDeskCore
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskPlugins

final class JiraTextAttachmentSessionTests: XCTestCase {
    func testExactDraftAndCurrentGrantChecksPrecedeTransport() async throws {
        AttachmentSessionProtocol.calls.withLock { $0 = 0 }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
        let vault = try JiraCredentialVault(configuration: config, store: MemorySecrets(scope: secretScope))
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 2000), scopes: ["write:jira-work", "read:jira-work"])
        try await vault.save(tokens)
        let resource = JiraCloudResource(id: UUID(), scopes: ["write:jira-work", "read:jira-work"])
        let transport = try JiraHTTPTransport(origin: resource.apiOrigin, protocolClasses: [AttachmentSessionProtocol.self])
        let session = JiraCloudSession(account: .init(accountID: "synthetic", displayName: "Synthetic"), transport: transport,
            configuration: config, resource: resource, tokens: tokens, vault: vault, now: { Date(timeIntervalSince1970: 1000) })
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(.attachmentsAdd, .approval), .init(.commentsRead, .approval)])
        let draft = try JiraTextAttachmentDraft(identifier: "A-1", filename: redactor.redactText("evidence.txt", in: context), content: redactor.redactText("Evidence", in: context))
        let prepared = try await session.prepareTextAttachment(draft, configurationRevision: 1, permissions: permissions, runID: context.runID)
        let changed = try JiraTextAttachmentDraft(identifier: "A-1", filename: redactor.redactText("evidence.txt", in: context), content: redactor.redactText("Changed", in: context))
        do { _ = try await session.executeTextAttachment(changed, prepared: prepared, permissions: permissions, redactor: redactor); XCTFail("Changed draft sent") }
        catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        let sensitive = try JiraTextAttachmentDraft(identifier: "A-1", filename: redactor.redactText("evidence.txt", in: context), content: redactor.redactText("Echo synthetic-access", in: context))
        let sensitiveAction = try await session.prepareTextAttachment(sensitive, configurationRevision: 1, permissions: permissions, runID: context.runID)
        do { _ = try await session.executeTextAttachment(sensitive, prepared: sensitiveAction, permissions: permissions, redactor: redactor); XCTFail("Credential sent") }
        catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        XCTAssertEqual(AttachmentSessionProtocol.calls.withLock { $0 }, 0)
        do {
            _ = try await session.executeTextAttachment(draft, prepared: prepared, permissions: permissions, redactor: redactor,
                beforeDispatch: { throw BugRegistryError.staleRevision })
            XCTFail("Stale evidence dispatched")
        } catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
        XCTAssertEqual(AttachmentSessionProtocol.calls.withLock { $0 }, 0)
        do {
            _ = try await session.executeTextAttachment(draft, prepared: prepared, permissions: permissions, redactor: redactor,
                beforeDispatch: { try await vault.logout() })
            XCTFail("Grant removed during evidence validation was used")
        } catch { XCTAssertEqual(error as? PluginConnectionError, .authenticationExpired) }
        XCTAssertEqual(AttachmentSessionProtocol.calls.withLock { $0 }, 0)
        try await vault.save(tokens)
        let receipt = try await session.executeTextAttachment(draft, prepared: prepared, permissions: permissions, redactor: redactor)
        XCTAssertEqual(receipt.id, "123")
        XCTAssertEqual(AttachmentSessionProtocol.calls.withLock { $0 }, 1)
        await session.close()
    }
}
private final class AttachmentSessionProtocol: URLProtocol {
    static let calls = Mutex(0)
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.calls.withLock { $0 += 1 }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"[{"id":"123","filename":"evidence.txt","size":8}]"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
