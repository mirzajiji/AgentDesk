import AgentDeskCore
import AgentDeskPersistence
import AgentDeskPlugins
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskRuntime

@MainActor final class StoredPluginPolicySessionTests: XCTestCase {
    func testStoredRulesGateDispatchAndEditsInvalidateApprovedActions() async throws {
        for disposition: PolicyDisposition in [.deny, .allow, .approval] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic")
            let project = try await catalog.createProject(in: workspace.id, name: "Stored policy")
            let scope = project.scope, environment = EnvironmentID(), id = UUID()
            let configurations = try await catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: scope)
            let permissions = try PluginPermissions(connectionID: id, scope: scope, environmentID: environment, rules: [.init(.issuesRead, disposition)])
            let config = try JiraConnectionConfiguration(id: id, scope: scope, environmentID: environment,
                instance: URL(string: "https://synthetic.atlassian.net")!, enabled: true, permissions: permissions)
            _ = try await configurations.save(config, in: scope, expectedRevision: nil)
            let rules = PolicyOperation.allCases.map { PolicyRule($0, .allow) }
            let policy = try PolicySnapshot(
                workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
                project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
                environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
            let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment],
                operations: [.readEvidence], canApprove: true, expiresAt: Date().addingTimeInterval(600))
            let approvals = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
            do {
                _ = try await PluginPolicySession.openStored(configurationStore: configurations, connectionID: id, scope: scope,
                    authorities: [user], requesterID: user.id, approvals: approvals, currentPolicy: { policy }, prepare: { record, permissions in
                        let staleSite = try JiraConnectionConfiguration(id: id, scope: scope, environmentID: environment,
                            instance: URL(string: "https://different.atlassian.net")!, enabled: true, permissions: permissions)
                        return try PreparedPluginAction(configuration: staleSite, configurationRevision: record.revision,
                            permissions: permissions, capability: .issuesRead, resource: .canonical("Synthetic issue"), payload: .canonical("Read"))
                    })
                XCTFail("Adapter changed the persisted site while retaining its identity")
            } catch { XCTAssertEqual(error as? AuthorizationError, .scopeMismatch) }
            let actionID = UUID()
            let session = try await PluginPolicySession.openStored(configurationStore: configurations, connectionID: id, scope: scope,
                authorities: [user], requesterID: user.id, approvals: approvals, currentPolicy: { policy }, prepare: { record, permissions in
                    try PreparedPluginAction(id: actionID, configuration: record.configuration, configurationRevision: record.revision,
                        permissions: permissions, capability: .issuesRead, resource: .canonical("Synthetic issue"), payload: .canonical("Read"))
                })
            let effects = Mutex(0)
            do {
                _ = try await session.execute { _ in effects.withLock { $0 += 1 } }
                XCTAssertEqual(disposition, .allow)
            } catch {
                XCTAssertEqual(error as? AuthorizationError, disposition == .deny ? .denied : .approvalRequired)
            }
            XCTAssertEqual(effects.withLock { $0 }, disposition == .allow ? 1 : 0)
            if disposition == .approval {
                guard case .approval(let pending) = try await session.prepare() else { return XCTFail("Missing approval") }
                _ = try await session.review(pending.id, reviewerID: user.id, approve: true, expectedSequence: pending.sequence)
                let revoked = try JiraConnectionConfiguration(id: id, scope: scope, environmentID: environment, instance: config.instance, enabled: true)
                _ = try await configurations.save(revoked, in: scope, expectedRevision: 1)
                do { _ = try await session.execute(approvalID: pending.id) { _ in effects.withLock { $0 += 1 } }; XCTFail("Stored change ignored") }
                catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
                XCTAssertEqual(effects.withLock { $0 }, 0)
            }
        }
    }
}
