import Foundation
import XCTest
@testable import AgentDeskCore

@MainActor
final class CityPayBugSkillTests: XCTestCase {
    func testTemplateInstallsAsScopedVersionedBundleWithSyntheticExamplesAndNoMutationPermission() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root), workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "Synthetic CityPay"), store = try await catalog.skillStore(in: project.scope)
        let owner = SkillScope(workspaceID: workspace.id, projectID: project.id)
        let initial = try await store.save(CityPayBugSkill.draft, at: owner, in: project.scope)
        XCTAssertEqual(initial.definition.requiredPermissions, [.readEvidence])
        XCTAssertTrue(initial.attachments.allSatisfy { $0.kind == .example })
        let folder = root.appendingPathComponent("\(workspace.id)/Projects/\(project.id)/Skills/\(initial.id)/Versions/1")
        let manifest = try Data(contentsOf: folder.appendingPathComponent("skill.json"))
        XCTAssertEqual(try JSONDecoder().decode(SkillDefinition.self, from: manifest), initial.definition)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("instructions.md"), encoding: .utf8), initial.instructions)
        var revised = initial.draft; revised.summary = "Locally reviewed wording"
        let updated = try await store.save(revised, at: owner, in: project.scope, id: initial.id, expectedRevision: 1)
        XCTAssertEqual(updated.definition.revision, 2)
        let pinned = try await store.skill(initial.definition.reference, in: project.scope)
        XCTAssertEqual(pinned, initial)
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("skill.json")), manifest)
        let foreign = try await catalog.createProject(in: workspace.id, name: "Separate project")
        let foreignStore = try await catalog.skillStore(in: foreign.scope)
        do { _ = try await foreignStore.skill(initial.definition.reference, in: foreign.scope); XCTFail("Project skill crossed scope") }
        catch { XCTAssertEqual(error as? SkillError, .scopeMismatch) }
    }
}
