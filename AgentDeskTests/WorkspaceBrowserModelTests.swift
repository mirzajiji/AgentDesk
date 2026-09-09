#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDesk

final class WorkspaceBrowserModelTests: XCTestCase {
    @MainActor
    func testCreationSelectionAndReopeningUsePersistentCatalog() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "AgentDesk.Tests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let catalog = try WorkspaceCatalog(container: root)
        let model = WorkspaceBrowserModel(catalog: catalog, preferences: preferences)
        await model.reload()
        XCTAssertTrue(model.workspaces.isEmpty)
        try await model.createWorkspace(name: "Personal")
        let first = try XCTUnwrap(model.selectedWorkspace)
        try await model.createProject(workspaceID: first, name: "AgentDesk")
        XCTAssertEqual(model.projects.map(\.name), ["AgentDesk"])
        try await model.createWorkspace(name: "Second")
        XCTAssertTrue(model.projects.isEmpty)
        await model.select(first)
        let reopened = WorkspaceBrowserModel(catalog: try WorkspaceCatalog(container: root), preferences: preferences)
        await reopened.reload()
        XCTAssertEqual(reopened.selectedWorkspace, first)
        XCTAssertEqual(reopened.projects.map(\.name), ["AgentDesk"])
        XCTAssertNil(reopened.errorMessage)
    }

    @MainActor
    func testSelectionFailureClearsPreviousProjectContent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "AgentDesk.Tests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let model = WorkspaceBrowserModel(catalog: try WorkspaceCatalog(container: root), preferences: preferences)
        try await model.createWorkspace(name: "Personal")
        try await model.createProject(workspaceID: XCTUnwrap(model.selectedWorkspace), name: "Private")
        await model.select(WorkspaceID())
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertNotNil(model.errorMessage)
        await model.reload()
        XCTAssertEqual(model.projects.map(\.name), ["Private"])
        XCTAssertNil(model.errorMessage)
    }

    @MainActor
    func testRenamesKeepSelectionAndScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "AgentDesk.Tests.\(UUID().uuidString)"
        let preferences = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { try? FileManager.default.removeItem(at: root); preferences.removePersistentDomain(forName: suite) }
        let model = WorkspaceBrowserModel(catalog: try WorkspaceCatalog(container: root), preferences: preferences)
        try await model.createWorkspace(name: "Before")
        let workspaceID = try XCTUnwrap(model.selectedWorkspace)
        try await model.createProject(workspaceID: workspaceID, name: "Before")
        let scope = try XCTUnwrap(model.projects.first?.scope)
        try await model.renameWorkspace(workspaceID, name: "After")
        try await model.renameProject(scope, name: "After")
        XCTAssertEqual(model.currentWorkspace?.name, "After")
        XCTAssertEqual(model.projects.first?.scope, scope)
        XCTAssertEqual(model.projects.first?.name, "After")
    }
}
#endif
