import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraStoredPermissionsTests: XCTestCase {
    @MainActor func testPermissionsSurviveReopenAndPreserveHistoricalDenial() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "Permissions")
        let store = try await catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: project.scope)
        let first = try JiraConnectionConfiguration(scope: project.scope, environmentID: EnvironmentID(), instance: URL(string: "https://synthetic.atlassian.net")!)
        _ = try await store.save(first, in: project.scope, expectedRevision: nil)
        let permissions = try PluginPermissions(connectionID: first.id, scope: first.scope, environmentID: first.environmentID,
            rules: [.init(.issuesRead, .approval)])
        let second = try JiraConnectionConfiguration(id: first.id, scope: first.scope, environmentID: first.environmentID,
            instance: first.instance, permissions: permissions)
        _ = try await store.save(second, in: project.scope, expectedRevision: 1)
        let reopened = try await WorkspaceCatalog(container: root).pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: project.scope)
        let current = try await reopened.read(id: first.id, in: project.scope)
        let historical = try await reopened.read(id: first.id, in: project.scope, revision: 1)
        XCTAssertEqual(current?.configuration.permissions, permissions)
        XCTAssertEqual(try historical?.configuration.resolvedPermissions().disposition(for: .issuesRead), .deny)
        do { _ = try await reopened.save(first, in: project.scope, expectedRevision: 1); XCTFail("Stale permission edit accepted") }
        catch { XCTAssertEqual(error as? PluginStorageError, .staleRevision) }
    }

    func testLegacyDefaultsDenyAndExplicitPermissionsRoundTripWithScopeValidation() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID(), id = UUID()
        let site = URL(string: "https://synthetic.atlassian.net")!
        let legacy = try JiraConnectionConfiguration(id: id, scope: scope, environmentID: environment, instance: site)
        let decoded = try JSONDecoder().decode(JiraConnectionConfiguration.self, from: JSONEncoder().encode(legacy))
        XCTAssertNil(decoded.permissions)
        XCTAssertEqual(try legacy.resolvedPermissions(), try decoded.resolvedPermissions())
        for capability in PluginCapability.allCases { XCTAssertEqual(try decoded.resolvedPermissions().disposition(for: capability), .deny) }
        let permissions = try PluginPermissions(connectionID: id, scope: scope, environmentID: environment,
            rules: [.init(.issuesRead, .allow), .init(.commentsWrite, .approval)])
        let configured = try JiraConnectionConfiguration(id: id, scope: scope, environmentID: environment, instance: site, permissions: permissions)
        XCTAssertEqual(try JSONDecoder().decode(JiraConnectionConfiguration.self, from: JSONEncoder().encode(configured)), configured)
        XCTAssertEqual(try configured.resolvedPermissions(), permissions)
        for invalid in [
            try PluginPermissions(connectionID: UUID(), scope: scope, environmentID: environment, rules: []),
            try PluginPermissions(connectionID: id, scope: scope, environmentID: EnvironmentID(), rules: []),
            try PluginPermissions(connectionID: id, scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: environment, rules: [])
        ] {
            XCTAssertThrowsError(try JiraConnectionConfiguration(id: id, scope: scope, environmentID: environment, instance: site, permissions: invalid))
        }
    }
}
