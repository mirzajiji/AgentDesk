import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class PluginPermissionsTests: XCTestCase {
    func testIndependentCapabilitiesAndMissingRuleDeny() throws {
        let permissions = try PluginPermissions(connectionID: UUID(),
            scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()),
            environmentID: EnvironmentID(), rules: [.init(.issuesRead, .allow), .init(.commentsWrite, .approval)])
        XCTAssertEqual(permissions.disposition(for: .issuesRead), .allow)
        XCTAssertEqual(permissions.disposition(for: .commentsWrite), .approval)
        XCTAssertEqual(permissions.disposition(for: .issuesDelete), .deny)
        XCTAssertEqual(permissions.disposition(for: .issuesCreate), .deny)
        XCTAssertEqual(try JSONDecoder().decode(PluginPermissions.self, from: JSONEncoder().encode(permissions)), permissions)
    }
    func testCompositionNeverWeakensBasePolicyAndPreservesSafetyContext() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID(), connection = UUID()
        for original: PolicyDisposition in [.allow, .approval, .deny] {
            for grant: PolicyDisposition in [.allow, .approval, .deny] {
                let rules = PolicyOperation.allCases.map { PolicyRule($0, original) }
                let base = try PolicySnapshot(
                    workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
                    project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
                    environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID,
                        projectID: scope.projectID, environmentID: environment, rules: rules),
                    environmentKind: .production, workspaceLocked: true)
                let permissions = try PluginPermissions(connectionID: connection, scope: scope,
                    environmentID: environment, rules: [.init(.issuesCreate, grant)])
                let restricted = try permissions.restricting(base, connectionID: connection, capability: .issuesCreate)
                let expected: PolicyDisposition = original == .deny || grant == .deny ? .deny
                    : (original == .approval || grant == .approval ? .approval : .allow)
                XCTAssertEqual(restricted.environment.disposition(for: .externalMutation), expected)
                XCTAssertEqual(restricted.environment.disposition(for: .readEvidence), .deny)
                XCTAssertEqual(restricted.workspace, base.workspace)
                XCTAssertEqual(restricted.project, base.project)
                XCTAssertEqual(restricted.environmentKind, .production)
                XCTAssertTrue(restricted.workspaceLocked)
                XCTAssertThrowsError(try permissions.restricting(base, connectionID: UUID(), capability: .issuesCreate))
            }
        }
    }

    func testConflictingDuplicateRulesAreRejected() throws {
        XCTAssertThrowsError(try PluginPermissions(connectionID: UUID(),
            scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(),
            rules: [.init(.issuesRead, .deny), .init(.issuesRead, .allow)]))
    }
}
