import CryptoKit
import Foundation
import XCTest
@testable import AgentDeskCore

@MainActor
final class ProjectInstructionStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let catalog: WorkspaceCatalog
        let project: ProjectRecord
        let store: ProjectInstructionStore
        let agent: AgentSnapshot
        var workspaceRoot: URL { root.appendingPathComponent(project.workspaceID.rawValue) }
        var projectRoot: URL { workspaceRoot.appendingPathComponent("Projects/\(project.id)") }
        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic Workspace")
            project = try await catalog.createProject(in: workspace.id, name: "Synthetic Project")
            store = try await catalog.instructionStore(in: project.scope)
            let agents = try await catalog.agentStore(in: project.scope)
            agent = try await agents.create(AgentTemplate.general.draft, in: project.scope)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    private func draft(_ title: String, text: String = "Synthetic instructions") -> InstructionBundleDraft {
        let document = InstructionDocument(title: title, text: text)
        return InstructionBundleDraft(documents: [document], roots: [document.id])
    }

    func testAbsentSharedSetsUseOnlyGlobalAndExactAgentSnapshot() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let result = try await f.store.preview(for: f.agent, in: f.project.scope)
        XCTAssertEqual(result.sources.map(\.layer), ["Global", "Agent"])
        XCTAssertEqual(result.sources.last?.text, f.agent.instructions)
        XCTAssertEqual(result.agentRevision, f.agent.definition.revision)
        XCTAssertEqual(result.scope, f.project.scope)
        let missing = try await f.store.bundle(at: .workspace, in: f.project.scope)
        XCTAssertNil(missing)
    }

    func testCompositionResolvesIncludesOnceInLayerOrderAndExcludesUnselectedFiles() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let common = InstructionDocument(title: "Common", text: "abc")
        let main = InstructionDocument(title: "Workspace rules", text: "Workspace text", includes: [common.id])
        let unused = InstructionDocument(title: "Not selected", text: "Excluded synthetic text")
        let workspace = InstructionBundleDraft(documents: [main, common, unused], roots: [main.id, common.id])
        _ = try await f.store.save(workspace, at: .workspace, in: f.project.scope, expectedRevision: nil)
        _ = try await f.store.save(draft("Project rules"), at: .project, in: f.project.scope, expectedRevision: nil)
        let preview = try await f.store.preview(for: f.agent, in: f.project.scope)
        XCTAssertEqual(preview.sources.map(\.layer), ["Global", "Workspace", "Workspace", "Project", "Agent"])
        XCTAssertEqual(preview.sources[1].title, "Common")
        XCTAssertEqual(preview.sources[2].title, "Workspace rules")
        XCTAssertEqual(preview.sources[1].sha256, "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(preview.sources[1].relativeFile, "Instructions/Versions/1/\(common.id).md")
        XCTAssertFalse(preview.text.contains(unused.text))
        let reopened = try await f.catalog.instructionStore(in: f.project.scope)
        let repeated = try await reopened.preview(for: f.agent, in: f.project.scope)
        XCTAssertEqual(repeated, preview)
    }

    func testNewVersionsPreserveOriginalBytesAndFrozenPreview() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        var original = draft("Project", text: "Original synthetic instructions")
        let saved = try await f.store.save(original, at: .project, in: f.project.scope, expectedRevision: nil)
        let before = try await f.store.preview(for: f.agent, in: f.project.scope)
        let file = f.projectRoot.appendingPathComponent("Instructions/Versions/1/\(original.documents[0].id).md")
        let bytes = try Data(contentsOf: file)
        original.documents[0].text = "Changed synthetic instructions"
        let updated = try await f.store.save(original, at: .project, in: f.project.scope, expectedRevision: 1)
        XCTAssertEqual(updated.revision, 2)
        let historical = try await f.store.bundle(at: .project, in: f.project.scope, revision: 1)
        XCTAssertEqual(historical, saved)
        XCTAssertEqual(try Data(contentsOf: file), bytes)
        let after = try await f.store.preview(for: f.agent, in: f.project.scope)
        XCTAssertTrue(before.text.contains("Original synthetic instructions"))
        XCTAssertFalse(after.text.contains("Original synthetic instructions"))
        XCTAssertEqual(after.sources[1].revision, 2)
        XCTAssertNotEqual(before.sources[1].sha256, after.sources[1].sha256)
    }

    func testWorkspaceGuidanceIsSharedButProjectGuidanceIsIsolated() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        _ = try await f.store.save(draft("Workspace"), at: .workspace, in: f.project.scope, expectedRevision: nil)
        _ = try await f.store.save(draft("Only first project"), at: .project, in: f.project.scope, expectedRevision: nil)
        let second = try await f.catalog.createProject(in: f.project.workspaceID, name: "Second")
        let secondStore = try await f.catalog.instructionStore(in: second.scope)
        let workspace = try await secondStore.bundle(at: .workspace, in: second.scope)
        let project = try await secondStore.bundle(at: .project, in: second.scope)
        XCTAssertEqual(workspace?.draft.documents[0].title, "Workspace")
        XCTAssertNil(project)
        do { _ = try await secondStore.preview(for: f.agent, in: second.scope); XCTFail("Foreign agent accepted") }
        catch { XCTAssertEqual(error as? ScopedFileError, .scopeMismatch) }
    }

    func testForeignWorkspaceAndCopiedBundleAreRejected() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        _ = try await f.store.save(draft("Private synthetic rules"), at: .workspace, in: f.project.scope, expectedRevision: nil)
        let workspace = try await f.catalog.createWorkspace(name: "Unrelated Workspace")
        let project = try await f.catalog.createProject(in: workspace.id, name: "Unrelated Project")
        do { _ = try await f.store.bundle(at: .workspace, in: project.scope); XCTFail("Foreign read") }
        catch { XCTAssertEqual(error as? ScopedFileError, .scopeMismatch) }
        do { _ = try await f.store.save(draft("Forbidden"), at: .project, in: project.scope, expectedRevision: nil); XCTFail("Foreign write") }
        catch { XCTAssertEqual(error as? ScopedFileError, .scopeMismatch) }
        try FileManager.default.copyItem(at: f.workspaceRoot.appendingPathComponent("Instructions"),
                                        to: f.root.appendingPathComponent("\(workspace.id)/Instructions"))
        let other = try await f.catalog.instructionStore(in: project.scope)
        do { _ = try await other.bundle(at: .workspace, in: project.scope); XCTFail("Copied bundle accepted") }
        catch { XCTAssertEqual(error as? InstructionError, .invalidBundle) }
    }

    func testStaleEditorsAndConcurrentStoresCannotOverwriteHistory() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let first = try await f.store.save(draft("First"), at: .project, in: f.project.scope, expectedRevision: nil)
        let other = try await f.catalog.instructionStore(in: f.project.scope)
        let next = draft("Next")
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for store in [f.store, other] {
                group.addTask { (try? await store.save(next, at: .project, in: f.project.scope, expectedRevision: 1)) != nil }
            }
            var count = 0; for await result in group { if result { count += 1 } }; return count
        }
        XCTAssertEqual(successes, 1)
        do { _ = try await other.save(first.draft, at: .project, in: f.project.scope, expectedRevision: 1); XCTFail("Stale save") }
        catch { XCTAssertEqual(error as? InstructionError, .staleRevision) }
        let history = try await other.bundle(at: .project, in: f.project.scope, revision: 1)
        XCTAssertEqual(history, first)
    }

    func testMissingPointerAndOrphanVersionRemainRecoverableWithoutOverwrite() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let orphan = f.projectRoot.appendingPathComponent("Instructions/Versions/1")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        try Data("Unpublished synthetic version".utf8).write(to: orphan.appendingPathComponent("preserved.md"))
        let missing = try await f.store.bundle(at: .project, in: f.project.scope); XCTAssertNil(missing)
        let saved = try await f.store.save(draft("Recovered"), at: .project, in: f.project.scope, expectedRevision: nil)
        XCTAssertEqual(saved.revision, 2)
        XCTAssertEqual(try String(contentsOf: orphan.appendingPathComponent("preserved.md"), encoding: .utf8), "Unpublished synthetic version")
    }

    func testSymlinkAndPathSubstitutionInManifestAreRejected() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let content = draft("Synthetic")
        _ = try await f.store.save(content, at: .project, in: f.project.scope, expectedRevision: nil)
        let version = f.projectRoot.appendingPathComponent("Instructions/Versions/1")
        let file = version.appendingPathComponent("\(content.documents[0].id).md")
        let outside = f.root.appendingPathComponent("outside.md")
        try Data("Outside synthetic text".utf8).write(to: outside)
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        do { _ = try await f.store.preview(for: f.agent, in: f.project.scope); XCTFail("Symlink followed") }
        catch { XCTAssertEqual(error as? ScopedFileError, .unsafeFile) }
        let manifest = version.appendingPathComponent("instructions.json")
        let bytes = try Data(contentsOf: manifest)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var entries = try XCTUnwrap(json["documents"] as? [[String: Any]])
        entries[0]["file"] = "../../outside.md"; json["documents"] = entries
        try JSONSerialization.data(withJSONObject: json).write(to: manifest)
        do { _ = try await f.store.bundle(at: .project, in: f.project.scope); XCTFail("Path substitution accepted") }
        catch { XCTAssertEqual(error as? ScopedFileError, .invalidPath) }
    }

    func testMalformedCurrentPointerCannotBeSilentlyReplaced() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        _ = try await f.store.save(draft("Saved"), at: .project, in: f.project.scope, expectedRevision: nil)
        let pointer = f.projectRoot.appendingPathComponent("Instructions/current.json")
        let malformed = Data("{unsupported synthetic input".utf8)
        try malformed.write(to: pointer)
        do { _ = try await f.store.save(draft("New"), at: .project, in: f.project.scope, expectedRevision: nil); XCTFail("Malformed pointer replaced") }
        catch { XCTAssertEqual(error as? InstructionError, .invalidBundle) }
        XCTAssertEqual(try Data(contentsOf: pointer), malformed)
    }

    func testCancelledSaveLeavesNoCurrentSet() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let content = draft("Cancelled")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.store.save(content, at: .project, in: f.project.scope, expectedRevision: nil)
        }
        do { _ = try await task.value; XCTFail("Cancelled save succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let saved = try await f.store.bundle(at: .project, in: f.project.scope); XCTAssertNil(saved)
    }

    func testCyclesMissingReferencesAndDuplicateIdentitiesFailEvenWhenUnselected() throws {
        let a = InstructionID(), b = InstructionID()
        let cycle = InstructionBundleDraft(documents: [
            InstructionDocument(id: a, title: "A", text: "A", includes: [b]),
            InstructionDocument(id: b, title: "B", text: "B", includes: [a])])
        XCTAssertThrowsError(try cycle.resolvedDocuments()) { XCTAssertEqual($0 as? InstructionError, .circularReference) }
        let missing = InstructionBundleDraft(documents: [InstructionDocument(id: a, title: "A", text: "A", includes: [b])])
        XCTAssertThrowsError(try missing.resolvedDocuments()) { XCTAssertEqual($0 as? InstructionError, .missingReference) }
        let duplicate = InstructionBundleDraft(documents: [InstructionDocument(id: a, title: "A", text: "A"), InstructionDocument(id: a, title: "B", text: "B")])
        XCTAssertThrowsError(try duplicate.resolvedDocuments()) { XCTAssertEqual($0 as? InstructionError, .invalidBundle) }
    }

    func testSizeDepthAndContentValidationAreBounded() throws {
        XCTAssertThrowsError(try draft("Empty", text: " \n").resolvedDocuments())
        XCTAssertThrowsError(try draft("NUL", text: "a\u{0}b").resolvedDocuments())
        XCTAssertThrowsError(try draft("Oversized", text: String(repeating: "x", count: 65_537)).resolvedDocuments())
        let ids = (0..<34).map { _ in InstructionID() }
        let documents = ids.enumerated().reversed().map { index, id in
            InstructionDocument(id: id, title: "Node \(index)", text: "Synthetic", includes: index < 33 ? [ids[index + 1]] : [])
        }
        XCTAssertThrowsError(try InstructionBundleDraft(documents: documents, roots: []).resolvedDocuments()) {
            XCTAssertEqual($0 as? InstructionError, .sizeLimit)
        }
    }

    func testEmptyRevisionClearsCurrentGuidanceWithoutDeletingHistory() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let old = try await f.store.save(draft("Old"), at: .project, in: f.project.scope, expectedRevision: nil)
        _ = try await f.store.save(InstructionBundleDraft(), at: .project, in: f.project.scope, expectedRevision: 1)
        let preview = try await f.store.preview(for: f.agent, in: f.project.scope)
        XCTAssertEqual(preview.sources.map(\.layer), ["Global", "Agent"])
        let history = try await f.store.bundle(at: .project, in: f.project.scope, revision: 1)
        XCTAssertEqual(history, old)
    }
}
