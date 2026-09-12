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
        try await exercise(.issue(identifier: "A-1"), pathSuffix: "/issue/A-1")
    }
    func testAttachmentSettingsRequireIndependentReadApproval() async throws {
        try await exercise(.attachmentSettings, pathSuffix: "/attachment/meta")
    }
    func testNativeReadReviewUsesStoredRulesAndClosesItsConnection() async throws {
        for disposition: PolicyDisposition in [.deny, .approval] { try await exerciseNative(disposition) }
    }
    func testNativeReadReviewRejectsChangedConfigurationAfterApproval() async throws {
        try await exerciseNative(.approval, changeConfiguration: true)
    }
    private func exerciseNative(_ disposition: PolicyDisposition, changeConfiguration: Bool = false) async throws {
        let operation = JiraReadOperation.issue(identifier: "A-1")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "Native read")
        let scope = project.scope, environment = EnvironmentID()
        let configurations = try await catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: scope)
        let id = UUID()
        let permissions = try PluginPermissions(connectionID: id, scope: scope, environmentID: environment, rules: [.init(.issuesRead, disposition)])
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let config = try JiraConnectionConfiguration(id: id, scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true, permissions: permissions)
        _ = try await configurations.save(config, in: scope, expectedRevision: nil)
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
        let path = resource.apiOrigin.path + "/rest/api/3" + "/issue/A-1"
        let review = try await NativeJiraReadReview.open(connection: connection, operation: operation, configurations: configurations,
            connectionID: config.id, context: context, redactor: redactor, authorities: [user], requesterID: user.id,
            approvals: store, currentPolicy: { policy })
        do { _ = try await review.execute(); XCTFail("Unreviewed native read dispatched") }
        catch { XCTAssertEqual(error as? AuthorizationError, disposition == .deny ? .denied : .approvalRequired) }
        XCTAssertEqual(JiraPolicyProtocol.counts.withLock { $0[path, default: 0] }, 0)
        if disposition == .approval {
            guard case .approval(let pending) = try await review.prepare() else { return XCTFail("Missing native review") }
            _ = try await review.review(pending.id, approve: true, expectedSequence: pending.sequence)
            if changeConfiguration {
                let changed = try JiraConnectionConfiguration(id: id, scope: scope, environmentID: environment,
                    instance: config.instance, credential: config.credential, enabled: false, permissions: permissions)
                _ = try await configurations.save(changed, in: scope, expectedRevision: 1)
                do { _ = try await review.execute(approvalID: pending.id); XCTFail("Disabled connection dispatched") }
                catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
                XCTAssertEqual(JiraPolicyProtocol.counts.withLock { $0[path, default: 0] }, 0)
            } else {
                _ = try await review.execute(approvalID: pending.id)
                XCTAssertEqual(JiraPolicyProtocol.counts.withLock { $0[path, default: 0] }, 1)
                do { _ = try await review.execute(approvalID: pending.id); XCTFail("Native approval replayed") } catch { }
                XCTAssertEqual(JiraPolicyProtocol.counts.withLock { $0[path, default: 0] }, 1)
            }
        }
        await review.close()
        do { _ = try await review.prepare(); XCTFail("Closed native review accepted") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        do { _ = try await connection.prepare(operation, configurationRevision: 1, permissions: permissions, runID: context.runID); XCTFail("Owned connection remained open") }
        catch { XCTAssertEqual(error as? JiraTransportError, .closed) }
        _ = JiraPolicyProtocol.counts.withLock { $0.removeValue(forKey: path) }
    }
    private func exercise(_ operation: JiraReadOperation, pathSuffix: String) async throws {
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
        let path = resource.apiOrigin.path + "/rest/api/3" + pathSuffix
        for disposition: PolicyDisposition in [.deny, .approval] {
            let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(operation.capability, disposition)])
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
        let body = url.path.hasSuffix("/attachment/meta")
            ? #"{"enabled":true,"uploadLimit":8388608}"#
            : #"{"id":"123","key":"A-1","fields":{"summary":"Synthetic issue"}}"#
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
