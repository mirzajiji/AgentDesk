#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDesk

@MainActor
final class NativeCommandCatalogTests: XCTestCase {
    func testSearchKeepsSameNamedProjectsDistinctAndMatchesWorkspaceAndAccents() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceCatalog(container: root)
        let alpha = try await store.createWorkspace(name: "Alpha"), beta = try await store.createWorkspace(name: "Beta")
        let first = try await store.createProject(in: alpha.id, name: "Café"), second = try await store.createProject(in: beta.id, name: "Café")
        let catalog = NativeCommandCatalog(workspaces: [alpha, beta], projects: [first, second])
        XCTAssertEqual(catalog.search("RUN cafe").map(\.action), [.run(first.scope), .run(second.scope)])
        XCTAssertEqual(catalog.search("beta cafe run").map(\.action), [.run(second.scope)])
        XCTAssertEqual(catalog.search("beta requirements").map(\.action), [.requirements(second.scope)])
        XCTAssertTrue(catalog.search("not a capability").isEmpty)
        XCTAssertEqual(catalog.search("", limit: 1).map(\.action), [.settings])
        XCTAssertTrue(catalog.search("", limit: 0).isEmpty)
        XCTAssertEqual(Set(catalog.commands.map(\.id)).count, catalog.commands.count)
        let scoped = NativeCommandCatalog(workspaces: [alpha], projects: [first, second])
        XCTAssertFalse(scoped.commands.contains { $0.action == .run(second.scope) })
        XCTAssertFalse(scoped.commands.contains { $0.action == .requirements(second.scope) })
    }

    func testCommandDiscoveryCreatesNoRunStorageAndRoutingResolvesCurrentProject() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaces = root.appendingPathComponent("Workspaces")
        try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try WorkspaceCatalog(container: workspaces)
        let workspace = try await store.createWorkspace(name: "Synthetic")
        let project = try await store.createProject(in: workspace.id, name: "Before rename")
        let browser = WorkspaceBrowserModel(catalog: store, applicationRoot: root)
        try await browser.selectCommandWorkspace(workspace.id)
        XCTAssertEqual(browser.currentWorkspace?.id, workspace.id)
        XCTAssertEqual(browser.projects.map(\.id), [project.id])
        do { try await browser.selectCommandWorkspace(WorkspaceID()); XCTFail("Missing workspace selected") } catch {}
        XCTAssertEqual(browser.currentWorkspace?.id, workspace.id)
        let commands = try await browser.commands()
        XCTAssertEqual(commands.search("run before").first?.action, .run(project.scope))
        _ = try await store.renameProject(project.scope, name: "After rename")
        let resolvedWorkspace = try await browser.resolveWorkspace(workspace.id)
        XCTAssertEqual(resolvedWorkspace.id, workspace.id)
        do { _ = try await browser.resolveWorkspace(WorkspaceID()); XCTFail("Missing workspace routed") } catch {}
        let current = try await browser.resolveProject(project.scope)
        XCTAssertEqual(current.name, "After rename")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Data").path))
        let file = workspaces.appendingPathComponent("\(workspace.id)/Projects/\(project.id)/project.json")
        try FileManager.default.removeItem(at: file)
        do { _ = try await browser.resolveProject(project.scope); XCTFail("Stale project routed") } catch {}
        let foreign = ProjectScope(workspaceID: WorkspaceID(), projectID: project.id)
        do { _ = try await browser.resolveProject(foreign); XCTFail("Project resolved in another workspace") } catch {}
    }
}
#endif
