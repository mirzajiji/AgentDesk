#if os(macOS)
import AgentDeskCore
import AgentDeskPlugins
import XCTest
@testable import AgentDesk

@MainActor final class ProjectJiraConnectionsModelTests: XCTestCase {
    func testSaveReopenAndStaleEditPreserveVersions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "Connections")
        let store = try await catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: project.scope)
        let environment = ProjectEnvironment(scope: project.scope, name: "Development")
        let open = { NativeJiraConfigurationServices(store: store, environments: [environment]) }
        let model = ProjectJiraConnectionsModel(project: project, open: open)
        await model.load()
        XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.error)
        try await model.save(instance: "https://synthetic.atlassian.net", environment: environment.id, enabled: false, existing: nil)
        let first = try XCTUnwrap(model.records.first)
        XCTAssertEqual(first.revision, 1); XCTAssertFalse(first.configuration.enabled)
        let reopened = ProjectJiraConnectionsModel(project: project, open: open)
        await reopened.load()
        XCTAssertEqual(reopened.records.first?.configuration, first.configuration)
        try await reopened.save(instance: first.configuration.instance.absoluteString, environment: environment.id, enabled: true, existing: first)
        XCTAssertEqual(reopened.records.first?.revision, 2)
        do {
            try await model.save(instance: first.configuration.instance.absoluteString, environment: environment.id, enabled: false, existing: first)
            XCTFail("Stale editor replaced newer configuration")
        } catch { XCTAssertEqual(error as? PluginStorageError, .staleRevision) }
        for value in ["http://synthetic.atlassian.net", "https://synthetic.atlassian.net/private", "https://user:password@synthetic.atlassian.net"] {
            do { try await model.save(instance: value, environment: environment.id, enabled: false, existing: nil); XCTFail("Invalid site saved") }
            catch { XCTAssertEqual(error as? PluginConfigurationError, .invalidEndpoint) }
        }
        let page = try await store.list(in: project.scope)
        XCTAssertEqual(page.records.count, 1)
        XCTAssertEqual(page.records.first?.revision, 2)
        XCTAssertFalse(model.busy)
        let latest = try XCTUnwrap(reopened.records.first)
        try await reopened.savePermissions([.init(.issuesRead, .approval)], for: latest)
        let reviewed = try XCTUnwrap(reopened.records.first)
        XCTAssertEqual(reviewed.revision, 3)
        XCTAssertEqual(reviewed.configuration.permissions?.disposition(for: .issuesRead), .approval)
        try await reopened.save(instance: reviewed.configuration.instance.absoluteString, environment: environment.id, enabled: false, existing: reviewed)
        let edited = try XCTUnwrap(reopened.records.first)
        XCTAssertEqual(edited.configuration.permissions, reviewed.configuration.permissions)
        do { try await reopened.savePermissions([.init(.issuesRead, .allow)], for: latest); XCTFail("Stale permission edit accepted") }
        catch { XCTAssertEqual(error as? PluginStorageError, .staleRevision) }
        await reopened.resetConnection(edited)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.records.first?.configuration.permissions, reviewed.configuration.permissions)
    }

    func testCloseDiscardsLateLoadFailure() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "Connections")
        var pending: CheckedContinuation<Void, Never>?
        let model = ProjectJiraConnectionsModel(project: project) {
            await withCheckedContinuation { pending = $0 }
            throw PluginStorageError.scopeMismatch
        }
        let operation = Task { await model.load() }
        while pending == nil { await Task.yield() }
        model.close(); pending?.resume(); await operation.value
        XCTAssertFalse(model.busy); XCTAssertNil(model.error); XCTAssertTrue(model.records.isEmpty)
    }
}
#endif
