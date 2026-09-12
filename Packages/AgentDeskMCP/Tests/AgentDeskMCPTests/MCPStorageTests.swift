import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskMCP

final class MCPStorageTests: XCTestCase {
    @MainActor
    func testReopenImmutableHistoryAndScopeIsolation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "MCP")
        let store = try await catalog.mcpConfigurationStore(for: MCPStdioConfiguration.self, in: project.scope)
        let path = try WorkspacePath(workspaceID: workspace.id, relativePath: "project")
        let first = try MCPStdioConfiguration(scope: project.scope, environmentID: EnvironmentID(), name: "Synthetic", executable: "/bin/example", workingDirectory: path)
        _ = try await store.save(first, in: project.scope, expectedRevision: nil)
        let second = try MCPStdioConfiguration(id: first.id, scope: first.scope, environmentID: first.environmentID, name: "Renamed", executable: first.executable, workingDirectory: path)
        _ = try await store.save(second, in: project.scope, expectedRevision: 1)
        do { _ = try await store.save(first, in: project.scope, expectedRevision: 1); XCTFail("Stale write") }
        catch { XCTAssertEqual(error as? MCPStorageError, .staleRevision) }
        let reopened = try await WorkspaceCatalog(container: root).mcpConfigurationStore(for: MCPStdioConfiguration.self, in: project.scope)
        let head = try await reopened.read(id: first.id, in: project.scope)
        let old = try await reopened.read(id: first.id, in: project.scope, revision: 1)
        XCTAssertEqual(head?.configuration, second); XCTAssertEqual(old?.configuration, first)
        let page = try await reopened.list(in: project.scope, environmentID: first.environmentID)
        XCTAssertEqual(page.records.count, 1)
        let other = ProjectScope(workspaceID: workspace.id, projectID: ProjectID())
        do { _ = try await reopened.read(id: first.id, in: other); XCTFail("Foreign read") }
        catch { XCTAssertEqual(error as? MCPStorageError, .scopeMismatch) }
    }
}
