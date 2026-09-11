import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskPlugins
@testable import AgentDeskRuntime

@MainActor final class JiraPolicyReadTests: XCTestCase {
    func testUnapprovedAndDeniedReadsNeverDispatchThenApprovalRunsOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date().addingTimeInterval(600), scopes: ["read:jira-work"])
        let vault = try JiraCredentialVault(configuration: config, store: JiraTestSecrets(scope: secretScope))
        try await vault.save(tokens)
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-work"])
        let transport = try JiraHTTPTransport(origin: resource.apiOrigin, protocolClasses: [JiraPolicyProtocol.self])
        let account = try JiraCloudAccount.decode(.init(status: 200, body: Data(#"{"accountId":"synthetic","displayName":"Synthetic","active":true}"#.utf8)))
        let connection = JiraCloudSession(account: account, transport: transport, configuration: config, resource: resource, tokens: tokens, vault: vault, now: { Date() })
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let rules = PolicyOperation.allCases.map { PolicyRule($0, .allow) }
        let policy = try PolicySnapshot(workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
            project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
            environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment], operations: [.readEvidence], canApprove: true, expiresAt: Date().addingTimeInterval(600))
        let store = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
        let path = resource.apiOrigin.path + "/rest/api/3/issue/A-1"
        for disposition: PolicyDisposition in [.deny, .approval] {
            let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(.issuesRead, disposition)])
            let operation = JiraReadOperation.issue(identifier: "A-1")
            let prepared = try await connection.prepare(operation, configurationRevision: 1, permissions: permissions, runID: context.runID)
            let gate = try PluginPolicySession(prepared: prepared, policy: policy, permissions: permissions, authorities: [user], requesterID: user.id, store: store, validateCurrent: { (prepared, policy) })
            do {
                _ = try await gate.executeJira(operation, connection: connection, permissions: permissions, context: context, redactor: redactor)
                XCTFail("Unauthorized read dispatched")
            } catch { XCTAssertEqual(error as? AuthorizationError, disposition == .deny ? .denied : .approvalRequired) }
            XCTAssertEqual(JiraPolicyProtocol.counts.withLock { $0[path, default: 0] }, 0)
            if disposition == .approval {
                guard case .approval(let pending) = try await gate.prepare() else { return XCTFail("Missing approval") }
                _ = try await gate.review(pending.id, reviewerID: user.id, approve: true, expectedSequence: pending.sequence)
                _ = try await gate.executeJira(operation, connection: connection, permissions: permissions, context: context, redactor: redactor, approvalID: pending.id)
                XCTAssertEqual(JiraPolicyProtocol.counts.withLock { $0[path, default: 0] }, 1)
                do {
                    _ = try await gate.executeJira(operation, connection: connection, permissions: permissions, context: context, redactor: redactor, approvalID: pending.id)
                    XCTFail("Read approval replayed")
                } catch { }
                XCTAssertEqual(JiraPolicyProtocol.counts.withLock { $0[path, default: 0] }, 1)
            }
        }
        await connection.close()
        _ = JiraPolicyProtocol.counts.withLock { $0.removeValue(forKey: path) }
    }
}
private actor JiraTestSecrets: SecretStore {
    nonisolated let scope: SecretScope
    private var values: [SecretReference: SecretValue] = [:]
    init(scope: SecretScope) { self.scope = scope }
    func set(_ value: SecretValue, for reference: SecretReference) throws { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; values[reference] = value }
    func get(_ reference: SecretReference) throws -> SecretValue? { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; return values[reference] }
    func delete(_ reference: SecretReference) throws { guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }; values.removeValue(forKey: reference) }
    func exists(_ reference: SecretReference) throws -> Bool { try get(reference) != nil }
}
private final class JiraPolicyProtocol: URLProtocol {
    static let counts = Mutex<[String: Int]>([:])
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.counts.withLock { $0[url.path, default: 0] += 1 }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"id":"123","key":"A-1","fields":{"summary":"Synthetic issue"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
