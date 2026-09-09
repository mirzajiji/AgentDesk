#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDesk

@MainActor
final class ProjectSkillsModelTests: XCTestCase {
    func testStaleSkillEditCannotReplaceNewVersionAndFailedReloadClearsStaleList() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "Synthetic")
        let store = try await catalog.skillStore(in: project.scope)
        let owner = SkillScope(workspaceID: workspace.id, projectID: project.id)
        let first = try await store.save(SkillDraft(name: "Review", instructions: "Original"), at: owner, in: project.scope)
        let model = ProjectSkillsModel(scope: project.scope, store: store)
        await model.load(); XCTAssertEqual(model.skills, [first])
        var updated = first.draft; updated.instructions = "Saved by another editor"
        let second = try await store.save(updated, at: owner, in: project.scope, id: first.id, expectedRevision: 1)
        do { try await model.save(first.draft, owner: owner, replacing: first); XCTFail() }
        catch { XCTAssertEqual(error as? SkillError, .staleRevision) }
        await model.load(); XCTAssertEqual(model.skills, [second]); XCTAssertNil(model.error)
        let pointer = root.appendingPathComponent("\(workspace.id)/Projects/\(project.id)/Skills/\(first.id)/current.json")
        try Data("{invalid".utf8).write(to: pointer)
        await model.load(); XCTAssertTrue(model.skills.isEmpty); XCTAssertNotNil(model.error); XCTAssertFalse(model.loading)
    }
}
#endif
