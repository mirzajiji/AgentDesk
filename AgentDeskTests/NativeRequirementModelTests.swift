#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDesk

@MainActor
final class NativeRequirementModelTests: XCTestCase {
    private struct Fixture {
        let root: URL, catalog: WorkspaceCatalog, project: ProjectRecord, store: ProjectRequirementStore
        let id = RequirementID(rawValue: "synthetic-rule")!
        var services: NativeRequirementServices { NativeRequirementServices(store: store, environments: [], environmentIssue: nil) }
        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic workspace")
            project = try await catalog.createProject(in: workspace.id, name: "Synthetic requirements")
            store = try await catalog.requirementStore(in: project.scope)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func draft(_ text: String = "Reviewed behavior", status: RequirementStatus = .active) -> RequirementDraft {
            RequirementDraft(description: text, changeReason: "Synthetic review", status: status)
        }
        func publish(_ draft: RequirementDraft, expected: Int? = nil) async throws -> RequirementVersion {
            let pending = try await store.prepare(draft, id: id, expectedVersion: expected, in: project.scope)
            return try await store.publishReviewed(pending, in: project.scope)
        }
    }

    func testEditorRequiresReviewAndCancellationLeavesNoPublishedVersion() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let model = RequirementEditorModel(store: f.store, existing: nil)
        model.idText = f.id.rawValue; model.draft = f.draft()
        let unreviewed = await model.publish(); XCTAssertNil(unreviewed)
        await model.prepare(); XCTAssertNotNil(model.proposal); XCTAssertEqual(model.changes.count, 10)
        let before = try await f.store.resolve(f.id, in: f.project.scope); XCTAssertNil(before)
        await model.cancelReview(); let cancelled = await model.publish(); XCTAssertNil(cancelled)
        let after = try await f.store.resolve(f.id, in: f.project.scope); XCTAssertNil(after)
    }

    func testPublicationUsesExactReviewedCandidateAndEditsPreserveHistory() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let model = RequirementEditorModel(store: f.store, existing: nil)
        model.idText = f.id.rawValue; model.draft = f.draft(); await model.prepare()
        model.draft.description = "A later binding mutation must not replace the reviewed content"
        let published = await model.publish()
        let first = try XCTUnwrap(published)
        XCTAssertEqual(first.content.description, "Reviewed behavior")
        let next = RequirementEditorModel(store: f.store, existing: first)
        await next.prepare(); XCTAssertNil(next.proposal); XCTAssertNotNil(next.errorMessage, "An edit needs a new change reason")
        next.draft.description = "Changed behavior"; next.draft.changeReason = "New reviewed reason"
        await next.prepare(); XCTAssertEqual(next.proposal?.candidate.version, 2)
        XCTAssertEqual(next.changes.map(\.field), ["Description", "Change reason"])
        let second = await next.publish(); XCTAssertEqual(second?.version, 2)
        let historical = try await f.store.resolve(f.id, selection: .historical(version: 1), in: f.project.scope)
        XCTAssertEqual(historical, first)
    }

    func testStaleEditorRequiresReloadAndForeignContextCannotPrepare() async throws {
        let f = try await Fixture(), other = try await Fixture(); defer { f.remove(); other.remove() }
        let first = try await f.publish(f.draft())
        let model = RequirementEditorModel(store: f.store, existing: first)
        model.draft.changeReason = "Old editor"
        _ = try await f.publish(f.draft("Another editor"), expected: 1)
        await model.prepare(); XCTAssertNil(model.proposal)
        XCTAssertTrue(model.errorMessage?.contains("changed") == true)
        let foreign = RequirementEditorModel(store: other.store, existing: first)
        foreign.draft.changeReason = "Invalid context"; await foreign.prepare()
        XCTAssertNil(foreign.proposal); XCTAssertNotNil(foreign.errorMessage)
        let records = try await other.store.list(in: other.project.scope); XCTAssertTrue(records.isEmpty)
    }

    func testJSONValidationPreservesDraftAndReviewCannotBeReplaced() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let model = RequirementEditorModel(store: f.store, existing: nil)
        model.idText = f.id.rawValue; model.draft = f.draft()
        let original = model.draft
        XCTAssertThrowsError(try model.applyJSON("{invalid")); XCTAssertEqual(model.draft, original)
        var changed = original
        changed.expectedBehavior = ["result": .object(["ok": .boolean(true), "values": .array([.null, .number(Decimal(string: "9007199254740993")!)])])]
        let json = String(decoding: try JSONEncoder().encode(changed), as: UTF8.self)
        try model.applyJSON(json); XCTAssertEqual(model.draft, changed)
        await model.prepare(); XCTAssertThrowsError(try model.applyJSON(json))
        XCTAssertEqual(model.proposal?.candidate.content, changed)
        await model.cancelReview()
    }

    func testBrowserSeparatesLatestPublishedActiveAndHistoricalVersions() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.publish(f.draft())
        _ = try await f.publish(f.draft("Proposed behavior", status: .draft), expected: 1)
        let model = ProjectRequirementsModel(project: f.project, open: { f.services })
        await model.load(); XCTAssertEqual(model.records.map(\.version), [2])
        await model.select(f.id)
        XCTAssertEqual(model.displayed?.version, 2); XCTAssertEqual(model.active?.version, 1)
        model.selectedVersion = 1; XCTAssertEqual(model.displayed?.content.description, "Reviewed behavior")
        let active = try await f.store.resolve(f.id, in: f.project.scope); XCTAssertEqual(active?.version, 1)
    }

    func testCancelledBrowserLoadCannotRestoreLateResults() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.publish(f.draft())
        let gate = RequirementOpeningGate()
        let model = ProjectRequirementsModel(project: f.project, open: { await gate.wait(); return f.services })
        let loading = Task { await model.load() }
        await gate.waitUntilEntered(); model.cancel(); await gate.release(); await loading.value
        XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.services); XCTAssertNil(model.selectedID)
        XCTAssertFalse(model.isLoading)
    }

    func testBrowserRejectsForeignStoreBeforePublishingRecords() async throws {
        let f = try await Fixture(), other = try await Fixture(); defer { f.remove(); other.remove() }
        _ = try await other.publish(other.draft())
        let model = ProjectRequirementsModel(project: f.project, open: { other.services })
        await model.load(); XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.services)
        XCTAssertNotNil(model.errorMessage)
    }

    func testNativeEnvironmentChoicesComeFromCurrentProjectSetup() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let setup = ProjectExecutionSetupService(catalog: f.catalog, scope: f.project.scope)
        let defaults = try await setup.proposedDefaults(at: .project)
        _ = try await setup.save(defaults, at: .project, expectedRevision: nil)
        let browser = WorkspaceBrowserModel(catalog: f.catalog, applicationRoot: f.root)
        let services = try await browser.requirementServices(for: f.project)
        XCTAssertEqual(services.store.scope, f.project.scope)
        XCTAssertEqual(services.environments, defaults.environments); XCTAssertNil(services.environmentIssue)
    }

    func testMissingSelectedRequirementShowsReadErrorInsteadOfEmptySuccess() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.publish(f.draft())
        let model = ProjectRequirementsModel(project: f.project, open: { f.services })
        await model.load()
        let pointer = f.root.appendingPathComponent("\(f.project.workspaceID)/Projects/\(f.project.id)/Memory/Requirements/\(f.id)/current.json")
        try FileManager.default.removeItem(at: pointer)
        await model.select(f.id)
        XCTAssertTrue(model.history.isEmpty); XCTAssertNil(model.displayed)
        XCTAssertTrue(model.errorMessage?.contains("could not be opened") == true)
        XCTAssertFalse(model.isSelecting)
    }
}

private actor RequirementOpeningGate {
    private var pending: CheckedContinuation<Void, Never>?
    private var entered: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { pending = $0; entered?.resume(); entered = nil } }
    func waitUntilEntered() async { if pending == nil { await withCheckedContinuation { entered = $0 } } }
    func release() { pending?.resume(); pending = nil }
}
#endif
