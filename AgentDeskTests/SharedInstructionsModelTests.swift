#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDesk

@MainActor
final class SharedInstructionsModelTests: XCTestCase {
    func testUnsavedEditsAndScopeSelectionCannotSaveToUnloadedScope() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "Synthetic")
        let store = try await catalog.instructionStore(in: project.scope)
        let model = SharedInstructionsModel(store: store, scope: project.scope)
        XCTAssertFalse(model.canEdit)
        await model.reload(); model.add()
        XCTAssertTrue(model.hasUnsavedChanges)
        model.level = .workspace
        XCTAssertFalse(model.canEdit)
        let saved = await model.save(); XCTAssertFalse(saved)
        let empty = try await store.bundle(at: .workspace, in: project.scope); XCTAssertNil(empty)
        await model.reload()
        XCTAssertFalse(model.hasUnsavedChanges); XCTAssertTrue(model.canEdit)
        XCTAssertTrue(model.draft.documents.isEmpty)
    }

    func testFailedLoadDisablesEditingAndStaleSaveRetainsDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "Synthetic")
        let store = try await catalog.instructionStore(in: project.scope)
        let model = SharedInstructionsModel(store: store, scope: project.scope)
        await model.reload(); model.add()
        let another = SharedInstructionsModel(store: store, scope: project.scope)
        await another.reload(); another.add()
        let firstSaved = await another.save(); XCTAssertTrue(firstSaved)
        let draft = model.draft
        let staleSaved = await model.save(); XCTAssertFalse(staleSaved)
        XCTAssertEqual(model.draft, draft); XCTAssertNotNil(model.errorMessage)
        let pointer = root.appendingPathComponent("\(workspace.id)/Projects/\(project.id)/Instructions/current.json")
        try Data("{broken".utf8).write(to: pointer)
        await model.reload()
        XCTAssertFalse(model.canEdit); XCTAssertTrue(model.draft.documents.isEmpty)
        let failedSave = await model.save(); XCTAssertFalse(failedSave)
        XCTAssertNotNil(model.errorMessage)
    }
}
#endif
