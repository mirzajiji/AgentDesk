import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskPlugins
@testable import AgentDeskRuntime

@MainActor final class JiraPolicyIssueEditTests: XCTestCase {
    func testReviewedEditConsumesApprovalForSuccessAndUnknownOutcome() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date().addingTimeInterval(600), scopes: ["read:jira-work", "write:jira-work"])
        let vault = try JiraCredentialVault(configuration: config, store: JiraEditPolicySecrets(scope: secretScope))
        try await vault.save(tokens)
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-work", "write:jira-work"])
        let transport = try JiraHTTPTransport(origin: resource.apiOrigin, protocolClasses: [JiraEditPolicyProtocol.self])
        let account = try JiraCloudAccount.decode(.init(status: 200, body: Data(#"{"accountId":"synthetic","displayName":"Synthetic","active":true}"#.utf8)))
        let connection = JiraCloudSession(account: account, transport: transport, configuration: config, resource: resource, tokens: tokens, vault: vault, now: { Date() })
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let rules = PolicyOperation.allCases.map { PolicyRule($0, .allow) }
        let policy = try PolicySnapshot(workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
            project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
            environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment], operations: [.readEvidence, .externalMutation], canApprove: true, expiresAt: Date().addingTimeInterval(600))
        let store = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
        let path = resource.apiOrigin.path + "/rest/api/3/issue/A-1"
        let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment,
            rules: [.init(.issuesRead, .allow), .init(.issuesUpdate, .approval)])
        let read = try await connection.prepare(.issue(identifier: "A-1"), configurationRevision: 1, permissions: permissions, runID: context.runID)
        let readGate = try PluginPolicySession(prepared: read, policy: policy, permissions: permissions, authorities: [user],
            requesterID: user.id, store: store, validateCurrent: { (read, policy) })
        guard case .executed(let snapshot) = try await readGate.executeJiraIssueSnapshot(identifier: "A-1", connection: connection,
            permissions: permissions, context: context, redactor: redactor) else { return XCTFail("No baseline") }
        let draft = try snapshot.edit(summary: redactor.redactText("After", in: context))
        for fail in [false, true] {
            JiraEditPolicyProtocol.failures.withLock { $0[path] = fail }
            let prepared = try await connection.prepareIssueEdit(draft, configurationRevision: 1, permissions: permissions, runID: context.runID)
            let gate = try PluginPolicySession(prepared: prepared, policy: policy, permissions: permissions, authorities: [user],
                requesterID: user.id, store: store, validateCurrent: { (prepared, policy) })
            let before = JiraEditPolicyProtocol.counts.withLock { $0[path, default: 0] }
            do {
                _ = try await gate.executeJiraIssueEdit(draft, connection: connection, permissions: permissions, redactor: redactor,
                    readSession: readGate, approvalID: UUID())
                XCTFail("Unknown approval dispatched")
            } catch { }
            XCTAssertEqual(JiraEditPolicyProtocol.counts.withLock { $0[path, default: 0] }, before)
            guard case .approval(let pending) = try await gate.prepare() else { return XCTFail("No review") }
            _ = try await gate.review(pending.id, reviewerID: user.id, approve: true, expectedSequence: pending.sequence)
            do {
                let result = try await gate.executeJiraIssueEdit(draft, connection: connection, permissions: permissions, redactor: redactor,
                    readSession: readGate, approvalID: pending.id)
                XCTAssertFalse(fail)
                guard case .executed(let receipt) = result else { return XCTFail("No acknowledgment") }
                XCTAssertEqual(receipt.identifier, "A-1")
            } catch {
                XCTAssertTrue(fail)
                XCTAssertEqual(error as? JiraMutationError, .outcomeUnknown)
            }
            XCTAssertEqual(JiraEditPolicyProtocol.counts.withLock { $0[path, default: 0] }, before + 2)
            let reopened = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
            let restoredGate = try PluginPolicySession(prepared: prepared, policy: policy, permissions: permissions, authorities: [user],
                requesterID: user.id, store: reopened, validateCurrent: { (prepared, policy) })
            do {
                _ = try await restoredGate.executeJiraIssueEdit(draft, connection: connection, permissions: permissions, redactor: redactor,
                    readSession: readGate, approvalID: pending.id)
                XCTFail("Consumed review replayed after reopening storage")
            } catch { }
            XCTAssertEqual(JiraEditPolicyProtocol.counts.withLock { $0[path, default: 0] }, before + 2)
        }
        // A valid write review cannot grant read authority to the separate preflight session.
        let restrictedUser = try PolicyAuthority(id: user.id, kind: .localUser, scopes: [scope], environments: [environment],
            operations: [.externalMutation], canApprove: true, expiresAt: Date().addingTimeInterval(600))
        let deniedRead = try PluginPolicySession(prepared: read, policy: policy, permissions: permissions, authorities: [restrictedUser],
            requesterID: user.id, store: store, validateCurrent: { (read, policy) })
        let blockedEdit = try await connection.prepareIssueEdit(draft, configurationRevision: 1, permissions: permissions, runID: context.runID)
        let blockedGate = try PluginPolicySession(prepared: blockedEdit, policy: policy, permissions: permissions, authorities: [user],
            requesterID: user.id, store: store, validateCurrent: { (blockedEdit, policy) })
        guard case .approval(let blockedReview) = try await blockedGate.prepare() else { return XCTFail("No write review") }
        _ = try await blockedGate.review(blockedReview.id, reviewerID: user.id, approve: true, expectedSequence: blockedReview.sequence)
        let beforeDeniedRead = JiraEditPolicyProtocol.counts.withLock { $0[path, default: 0] }
        do {
            _ = try await blockedGate.executeJiraIssueEdit(draft, connection: connection, permissions: permissions, redactor: redactor,
                readSession: deniedRead, approvalID: blockedReview.id)
            XCTFail("Write review bypassed read authority")
        } catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        XCTAssertEqual(JiraEditPolicyProtocol.counts.withLock { $0[path, default: 0] }, beforeDeniedRead)
        // Even when reads become available, the consumed write approval is not restored.
        do {
            _ = try await blockedGate.executeJiraIssueEdit(draft, connection: connection, permissions: permissions, redactor: redactor,
                readSession: readGate, approvalID: blockedReview.id)
            XCTFail("Failed preflight restored consumed write review")
        } catch { }
        XCTAssertEqual(JiraEditPolicyProtocol.counts.withLock { $0[path, default: 0] }, beforeDeniedRead)
        await connection.close()
        _ = JiraEditPolicyProtocol.counts.withLock { $0.removeValue(forKey: path) }
        _ = JiraEditPolicyProtocol.failures.withLock { $0.removeValue(forKey: path) }
    }
}
private actor JiraEditPolicySecrets: SecretStore {
    nonisolated let scope: SecretScope
    private var values: [SecretReference: SecretValue] = [:]
    init(scope: SecretScope) { self.scope = scope }
    func set(_ value: SecretValue, for reference: SecretReference) throws { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; values[reference] = value }
    func get(_ reference: SecretReference) throws -> SecretValue? { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; return values[reference] }
    func delete(_ reference: SecretReference) throws { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; values.removeValue(forKey: reference) }
    func exists(_ reference: SecretReference) throws -> Bool { try get(reference) != nil }
}
private final class JiraEditPolicyProtocol: URLProtocol {
    static let failures = Mutex<[String: Bool]>([:])
    static let counts = Mutex<[String: Int]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.counts.withLock { $0[url.path, default: 0] += 1 }
        if request.httpMethod == "PUT" {
            if Self.failures.withLock({ $0[url.path, default: false] }) {
                client?.urlProtocol(self, didFailWithError: URLError(.networkConnectionLost))
            } else {
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 204, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocolDidFinishLoading(self)
            }
            return
        }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"123","key":"A-1","fields":{"updated":"2026-09-11T12:00:00Z","summary":"Before"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
