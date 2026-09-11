import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskPlugins
@testable import AgentDeskRuntime

@MainActor final class JiraPolicyCommentTests: XCTestCase {
    func testUnapprovedAndDeniedCommentsNeverDispatchThenApprovalRunsOnce() async throws {
        try await exerciseDispatch(networkFailure: false)
    }
    func testUnknownOutcomeStillConsumesApprovalAcrossReopen() async throws {
        try await exerciseDispatch(networkFailure: true)
    }
    func testDuplicateEvidenceRevalidatesThroughApprovedDispatch() async throws {
        try await exerciseDispatch(networkFailure: false, evidenceMode: true)
    }
    private func exerciseDispatch(networkFailure: Bool, evidenceMode: Bool = false) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date().addingTimeInterval(600), scopes: ["write:jira-work"])
        let vault = try JiraCredentialVault(configuration: config, store: JiraCommentPolicySecrets(scope: secretScope))
        try await vault.save(tokens)
        let resource = JiraCloudResource(id: UUID(), scopes: ["write:jira-work"])
        let transport = try JiraHTTPTransport(origin: resource.apiOrigin, protocolClasses: [JiraCommentPolicyProtocol.self])
        let account = try JiraCloudAccount.decode(.init(status: 200, body: Data(#"{"accountId":"synthetic","displayName":"Synthetic","active":true}"#.utf8)))
        let connection = JiraCloudSession(account: account, transport: transport, configuration: config, resource: resource, tokens: tokens, vault: vault, now: { Date() })
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let rules = PolicyOperation.allCases.map { PolicyRule($0, .allow) }
        let policy = try PolicySnapshot(workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
            project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
            environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment], operations: [.externalMutation], canApprove: true, expiresAt: Date().addingTimeInterval(600))
        let store = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
        let identifier = networkFailure ? "SYN-2" : "SYN-1"
        let path = resource.apiOrigin.path + "/rest/api/3/issue/\(identifier)/comment"
        for disposition: PolicyDisposition in [.deny, .approval] {
            let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(.commentsWrite, disposition)])
            let operation = try JiraCommentDraft(identifier: identifier, content: redactor.redactText("Reviewed evidence", in: context))
            let prepared = try await connection.prepareComment(operation, configurationRevision: 1, permissions: permissions, runID: context.runID)
            let gate = try PluginPolicySession(prepared: prepared, policy: policy, permissions: permissions, authorities: [user], requesterID: user.id, store: store, validateCurrent: { (prepared, policy) })
            do {
                _ = try await gate.executeJiraComment(operation, connection: connection, permissions: permissions, context: context, redactor: redactor)
                XCTFail("Unauthorized comment dispatched")
            } catch { XCTAssertEqual(error as? AuthorizationError, disposition == .deny ? .denied : .approvalRequired) }
            XCTAssertEqual(JiraCommentPolicyProtocol.counts.withLock { $0[path, default: 0] }, 0)
            if disposition == .approval {
                guard case .approval(let pending) = try await gate.prepare() else { return XCTFail("Missing approval") }
                _ = try await gate.review(pending.id, reviewerID: user.id, approve: true, expectedSequence: pending.sequence)
                do {
                    if evidenceMode {
                        let validations = Mutex(0)
                        let source = BugTicketEvidenceDraft(incomingID: BugID(), existingID: BugID(),
                            ticket: try ExternalBugTicket(key: identifier, url: "https://synthetic.atlassian.net/browse/" + identifier),
                            content: operation.content, expiresAt: Date().addingTimeInterval(600), owner: UUID(),
                            validate: { validations.withLock { $0 += 1 } })
                        let evidence = try await BugJiraComment.prepare(source, configuration: config)
                        _ = try await gate.executeBugJiraComment(evidence, connection: connection,
                            permissions: permissions, redactor: redactor, approvalID: pending.id)
                        XCTAssertEqual(validations.withLock { $0 }, 3,
                            "Validate at bridge preparation, policy entry and final transport dispatch")
                    } else {
                        _ = try await gate.executeJiraComment(operation, connection: connection, permissions: permissions, context: context, redactor: redactor, approvalID: pending.id)
                    }
                    XCTAssertFalse(networkFailure)
                } catch {
                    XCTAssertTrue(networkFailure)
                    XCTAssertEqual(error as? JiraMutationError, .outcomeUnknown)
                }
                XCTAssertEqual(JiraCommentPolicyProtocol.counts.withLock { $0[path, default: 0] }, 1)
                do {
                    _ = try await gate.executeJiraComment(operation, connection: connection, permissions: permissions, context: context, redactor: redactor, approvalID: pending.id)
                    XCTFail("Comment approval replayed")
                } catch { }
                let reopened = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
                let persisted = try await reopened.approval(pending.id)
                XCTAssertEqual(persisted?.state, .consumed)
                let restoredGate = try PluginPolicySession(prepared: prepared, policy: policy, permissions: permissions,
                    authorities: [user], requesterID: user.id, store: reopened, validateCurrent: { (prepared, policy) })
                do {
                    _ = try await restoredGate.executeJiraComment(operation, connection: connection, permissions: permissions,
                        context: context, redactor: redactor, approvalID: pending.id)
                    XCTFail("Persisted approval replayed through a new gate")
                } catch { }
                XCTAssertEqual(JiraCommentPolicyProtocol.counts.withLock { $0[path, default: 0] }, 1)
            }
        }
        let finalPermissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(.commentsWrite, .approval)])
        let finalDraft = try JiraCommentDraft(identifier: identifier, content: redactor.redactText("New reviewed evidence", in: context))
        let finalAction = try await connection.prepareComment(finalDraft, configurationRevision: 1, permissions: finalPermissions, runID: context.runID)
        let finalGate = try PluginPolicySession(prepared: finalAction, policy: policy, permissions: finalPermissions,
            authorities: [user], requesterID: user.id, store: store, validateCurrent: { (finalAction, policy) })
        guard case .approval(let review) = try await finalGate.prepare() else { return XCTFail("Missing final review") }
        _ = try await finalGate.review(review.id, reviewerID: user.id, approve: true, expectedSequence: review.sequence)
        do {
            _ = try await finalGate.executeJiraComment(finalDraft, connection: connection, permissions: finalPermissions,
                context: context, redactor: redactor, approvalID: review.id,
                beforeDispatch: { await finalGate.removeAuthority(user.id) })
            XCTFail("Authority revoked during evidence validation still dispatched")
        } catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        XCTAssertEqual(JiraCommentPolicyProtocol.counts.withLock { $0[path, default: 0] }, 1)
        await connection.close()
        _ = JiraCommentPolicyProtocol.counts.withLock { $0.removeValue(forKey: path) }
    }
}
private actor JiraCommentPolicySecrets: SecretStore {
    nonisolated let scope: SecretScope
    private var values: [SecretReference: SecretValue] = [:]
    init(scope: SecretScope) { self.scope = scope }
    func set(_ value: SecretValue, for reference: SecretReference) throws { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; values[reference] = value }
    func get(_ reference: SecretReference) throws -> SecretValue? { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; return values[reference] }
    func delete(_ reference: SecretReference) throws { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; values.removeValue(forKey: reference) }
    func exists(_ reference: SecretReference) throws -> Bool { try get(reference) != nil }
}
private final class JiraCommentPolicyProtocol: URLProtocol {
    static let counts = Mutex<[String: Int]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.counts.withLock { $0[url.path, default: 0] += 1 }
        if url.path.contains("/SYN-2/") {
            client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 201, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"123","key":"A-1","fields":{"summary":"Synthetic issue"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
