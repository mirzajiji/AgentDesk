#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import XCTest
@testable import AgentDesk

@MainActor final class ProjectMCPConnectionsModelTests: XCTestCase {
    func testSaveReopenAndStaleEditPreserveVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "Connections")
        let store = try await catalog.mcpConfigurationStore(for: MCPStdioConfiguration.self, in: project.scope)
        let environment = ProjectEnvironment(scope: project.scope, name: "Development")
        let open = { NativeMCPConfigurationServices(store: store, environments: [environment]) }
        let model = ProjectMCPConnectionsModel(project: project, open: open)
        await model.load()
        XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.error)
        try await model.save(name: "Synthetic", executable: "/bin/example", arguments: [], directory: "project", environment: environment.id, enabled: false, existing: nil)
        let first = try XCTUnwrap(model.records.first)
        XCTAssertEqual(first.revision, 1); XCTAssertFalse(first.configuration.enabled)
        let reopened = ProjectMCPConnectionsModel(project: project, open: open)
        await reopened.load()
        XCTAssertEqual(reopened.records.first?.configuration, first.configuration)
        try await reopened.save(name: "Synthetic", executable: first.configuration.executable, arguments: [], directory: "project", environment: environment.id, enabled: true, existing: first)
        XCTAssertEqual(reopened.records.first?.revision, 2)
        do {
            try await model.save(name: "Synthetic", executable: first.configuration.executable, arguments: [], directory: "project", environment: environment.id, enabled: false, existing: first)
            XCTFail("Stale editor replaced newer configuration")
        } catch { XCTAssertEqual(error as? MCPStorageError, .staleRevision) }
        for value in ["relative", "/a/../b", "/a//b"] {
            do { try await model.save(name: "Synthetic", executable: value, arguments: [], directory: "project", environment: environment.id, enabled: false, existing: nil); XCTFail("Invalid site saved") }
            catch { XCTAssertEqual(error as? MCPConfigurationError, .invalidConfiguration) }
        }
        let page = try await store.list(in: project.scope)
        XCTAssertEqual(page.records.count, 1)
        XCTAssertEqual(page.records.first?.revision, 2)
        XCTAssertFalse(model.busy)
    }
}
#endif
