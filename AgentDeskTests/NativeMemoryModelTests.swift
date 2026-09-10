#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDesk

@MainActor
final class NativeMemoryModelTests: XCTestCase {
    private struct Fixture {
        let root: URL, catalog: WorkspaceCatalog, project: ProjectRecord, store: ProjectMemoryStore
        var services: NativeMemoryServices { .init(store: store, environments: [], environmentIssue: nil) }
        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic")
            project = try await catalog.createProject(in: workspace.id, name: "Memory")
            store = try await catalog.memoryStore(in: project.scope)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func create(_ title: String, kind: MemoryKind = .note) async throws -> MemoryRecord {
            let draft = MemoryDraft(kind: kind, topic: .architecture, title: title, body: "Synthetic content",
                sources: [.init(scope: project.scope, origin: .humanStatement, label: "Local statement", capturedAt: Date())], changeReason: "Created")
            let proposal = try await store.prepare(draft, in: project.scope)
            return try await store.publishReviewed(proposal, in: project.scope)
        }
    }
    func testSearchFilterChangesResetPagingAndVersionSelectionPreservesHistory() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let note = try await f.create("Synthetic note"), confirmed = try await f.create("Confirmed rule", kind: .confirmed)
        let model = ProjectMemoryModel(project: f.project, open: { f.services })
        await model.load(); XCTAssertEqual(model.records.count, 2)
        await model.select(note.id); XCTAssertEqual(model.displayed?.revision, 1)
        model.filter.query = "Confirmed"; await model.load(more: true)
        XCTAssertEqual(model.records.map(\.id), [confirmed.id]); XCTAssertNil(model.selectedID)
        model.filter.query = ""; model.filter.kind = .note; await model.load()
        XCTAssertEqual(model.records.map(\.id), [note.id])
        var content = note.content; content.body = "Revised synthetic content"; content.changeReason = "Reviewed update"
        let proposal = try await f.store.prepare(content, id: note.id, expectedRevision: 1, in: f.project.scope)
        let updated = try await f.store.publishReviewed(proposal, in: f.project.scope)
        await model.didPublish(updated); XCTAssertEqual(model.history.map(\.revision), [2, 1])
        model.selectedRevision = 1; XCTAssertEqual(model.displayed?.content.body, "Synthetic content")
        model.cancel(); XCTAssertTrue(model.records.isEmpty); XCTAssertTrue(model.history.isEmpty); XCTAssertNil(model.services)
    }
    func testEditorPublishesOnlyReviewedSanitizedContentAndCancellationWritesNothing() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let model = MemoryEditorModel(store: f.store, existing: nil)
        model.draft.title = "Synthetic note"; model.draft.body = "Reviewed synthetic content"; model.draft.changeReason = "Created"
        model.draft.structured = ["password": .text("synthetic-editor-secret"), "count": .number(2)]
        let unreviewed = await model.publish(); XCTAssertNil(unreviewed)
        await model.prepare(); XCTAssertNotNil(model.proposal); XCTAssertTrue(model.redacted)
        XCTAssertFalse(model.after?.contains("synthetic-editor-secret") == true)
        XCTAssertFalse(model.changes.contains { $0.after.contains("synthetic-editor-secret") })
        let before = try await f.store.list(in: f.project.scope); XCTAssertTrue(before.isEmpty)
        await model.cancelReview(); XCTAssertNil(model.proposal)
        let cancelled = await model.publish(); XCTAssertNil(cancelled)
        await model.prepare(); model.draft.body = "Unreviewed binding change"
        let result = await model.publish(), saved = try XCTUnwrap(result)
        XCTAssertEqual(saved.content.body, "Reviewed synthetic content")
        XCTAssertNotEqual(saved.content.structured["password"], .text("synthetic-editor-secret"))
        XCTAssertEqual(saved.content.sources.first?.origin, .humanStatement)
    }
    func testPromotionAndArchivePreserveHistoryAndStaleReviewIsRejected() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let original = try await f.create("Synthetic note")
        let promotion = MemoryEditorModel(store: f.store, existing: original)
        promotion.draft.kind = .confirmed; promotion.draft.changeReason = "Reviewed confirmation"
        await promotion.prepare()
        XCTAssertEqual(promotion.changes.map(\.field), ["Kind", "Reason"])
        let promoted = await promotion.publish(), confirmed = try XCTUnwrap(promoted)
        XCTAssertEqual(confirmed.content.kind, .confirmed); XCTAssertEqual(confirmed.content.sources, original.content.sources)
        let archive = MemoryEditorModel(store: f.store, existing: confirmed)
        archive.draft.disposition = .archived; archive.draft.changeReason = "Reviewed archive"; await archive.prepare()
        let competing = MemoryEditorModel(store: f.store, existing: confirmed)
        competing.draft.body = "Concurrent reviewed change"; competing.draft.changeReason = "Update"; await competing.prepare()
        let archived = await archive.publish(); XCTAssertEqual(archived?.content.disposition, .archived)
        let stale = await competing.publish(); XCTAssertNil(stale); XCTAssertNotNil(competing.error)
        let history = try await f.store.history(original.id, in: f.project.scope)
        XCTAssertEqual(history.map(\.revision), [3, 2, 1]); XCTAssertEqual(history.last?.content.kind, .note)
    }
    func testForeignStoreFailsWithoutExposingRecords() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.create("Private synthetic record")
        let foreign = try await f.catalog.createProject(in: f.project.workspaceID, name: "Other")
        let model = ProjectMemoryModel(project: foreign, open: { f.services })
        await model.load()
        XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.services); XCTAssertNotNil(model.error)
    }

    func testReviewDetectsTagBoundariesRatherThanComparingJoinedLabels() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await f.create("Synthetic tags")
        var old = record.content; old.tags = ["a, b", "c"]
        var next = old; next.tags = ["a", "b, c"]
        let changes = try MemoryPresentation.changes(before: old, after: next)
        XCTAssertEqual(changes.map(\.field), ["Tags"])
        XCTAssertNotEqual(changes.first?.before, changes.first?.after)
    }

    func testArchivePublicationRespectsFiltersAndJSONRejectsForeignSources() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let original = try await f.create("Synthetic archive")
        let browser = ProjectMemoryModel(project: f.project, open: { f.services })
        await browser.load(); await browser.select(original.id)
        let editor = MemoryEditorModel(store: f.store, existing: original)
        var foreign = original.content
        foreign.sources = [.init(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), origin: .humanStatement,
            label: "Foreign source", capturedAt: Date())]
        XCTAssertThrowsError(try editor.applyJSON(MemoryPresentation.json(foreign)))
        XCTAssertEqual(editor.draft.sources, original.content.sources)
        editor.draft.disposition = .archived; editor.draft.changeReason = "Reviewed archive"
        await editor.prepare(); let result = await editor.publish(); let archived = try XCTUnwrap(result)
        await browser.didPublish(archived)
        XCTAssertTrue(browser.records.isEmpty); XCTAssertNil(browser.displayed)
        browser.filter.includeInactive = true; await browser.load(); await browser.select(original.id)
        XCTAssertEqual(browser.displayed?.revision, 2)
    }
}
#endif
