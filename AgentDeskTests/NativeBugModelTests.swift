#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDesk

@MainActor
final class NativeBugModelTests: XCTestCase {
    private struct Fixture {
        let root: URL, catalog: WorkspaceCatalog, project: ProjectRecord, store: ProjectBugStore
        var services: NativeBugServices { .init(store: store, environments: [], environmentIssue: nil) }
        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic")
            project = try await catalog.createProject(in: workspace.id, name: "Bugs")
            store = try await catalog.bugStore(in: project.scope)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func create(_ title: String) async throws -> BugRecord {
            let draft = BugDraft(title: title, sources: [.init(scope: project.scope, origin: .humanStatement, label: "Synthetic report", capturedAt: Date())], changeReason: "Created")
            return try await store.publishReviewed(store.prepare(draft, in: project.scope), in: project.scope)
        }
    }
    func testReviewedTicketLinkUnlinkAndSanitizedContentPreserveHistory() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let model = BugEditorModel(store: f.store, existing: nil)
        model.draft.title = "Synthetic bug"; model.draft.changeReason = "Local report"
        model.draft.details = ["password": .text("synthetic-bug-secret"), "status": .number(400)]
        model.draft.ticket = try .init(key: "SYN-42", url: "https://example.test/browse/SYN-42")
        let unreviewed = await model.publish(); XCTAssertNil(unreviewed)
        await model.prepare(); XCTAssertNotNil(model.proposal); XCTAssertTrue(model.redacted)
        XCTAssertFalse(model.fields.contains { $0.after.contains("synthetic-bug-secret") })
        await model.cancelReview()
        let empty = try await f.store.list(in: f.project.scope); XCTAssertTrue(empty.isEmpty)
        await model.prepare(); model.draft.title = "Unreviewed change"
        let result = await model.publish(), saved = try XCTUnwrap(result)
        XCTAssertEqual(saved.content.title, "Synthetic bug"); XCTAssertEqual(saved.content.ticket?.key, "SYN-42")
        let unlink = BugEditorModel(store: f.store, existing: saved)
        unlink.draft.ticket = nil; unlink.draft.changeReason = "Reviewed unlink"
        await unlink.prepare(); XCTAssertEqual(unlink.fields.first(where: { $0.id == "ticket" })?.after, "None")
        let unlinked = await unlink.publish(); XCTAssertNil(unlinked?.content.ticket)
        let history = try await f.store.history(saved.id, in: f.project.scope)
        XCTAssertEqual(history.map(\.revision), [2, 1]); XCTAssertEqual(history.last?.content.ticket?.key, "SYN-42")
    }
    func testBrowserFiltersAndIncomingLinksNavigateWithinProject() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let target = try await f.create("Synthetic upstream")
        let editor = BugEditorModel(store: f.store, existing: nil)
        editor.draft.title = "Downstream"; editor.draft.changeReason = "Reviewed blocked finding"
        editor.draft.assessment = .blocked; editor.draft.relationships = [.init(kind: .blockedBy, target: target.id)]
        await editor.prepare(); let result = await editor.publish(), downstream = try XCTUnwrap(result)
        let browser = ProjectBugsModel(project: f.project, open: { f.services })
        await browser.load(); XCTAssertEqual(browser.records.count, 2)
        await browser.select(target.id); XCTAssertEqual(browser.incoming.map(\.id), [downstream.id])
        await browser.select(downstream.id); XCTAssertEqual(browser.displayed?.content.relationships.first?.target, target.id)
        browser.filter.query = "upstream"; await browser.load(more: true)
        XCTAssertEqual(browser.records.map(\.id), [target.id]); XCTAssertNil(browser.selectedID)
        browser.filter.registered = true; await browser.load(); XCTAssertTrue(browser.records.isEmpty)
        browser.cancel(); XCTAssertNil(browser.services); XCTAssertTrue(browser.history.isEmpty)
    }
    func testInvalidObservedFindingForeignSourcesAndStaleReviewFailClosed() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let model = BugEditorModel(store: f.store, existing: nil)
        model.draft.title = "Unverified"; model.draft.changeReason = "Report"; model.draft.assessment = .observed
        await model.prepare(); XCTAssertNil(model.proposal); XCTAssertNotNil(model.error)
        var foreign = model.draft; foreign.assessment = .reported
        foreign.sources = [.init(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), origin: .humanStatement, label: "Foreign", capturedAt: Date())]
        XCTAssertThrowsError(try model.applyJSON(BugPresentation.json(foreign)))
        let saved = try await f.create("Original")
        let first = BugEditorModel(store: f.store, existing: saved), second = BugEditorModel(store: f.store, existing: saved)
        first.draft.status = .archived; first.draft.changeReason = "Archive"; await first.prepare()
        second.draft.title = "Competing edit"; second.draft.changeReason = "Edit"; await second.prepare()
        let archived = await first.publish(); XCTAssertEqual(archived?.content.status, .archived)
        let stale = await second.publish(); XCTAssertNil(stale); XCTAssertNotNil(second.error)
        let other = try await f.catalog.createProject(in: f.project.workspaceID, name: "Other")
        let browser = ProjectBugsModel(project: other, open: { f.services })
        await browser.load(); XCTAssertNil(browser.services); XCTAssertTrue(browser.records.isEmpty); XCTAssertNotNil(browser.error)
    }

    func testReviewPreservesExactDecimalDetailsAndSourceClassification() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let original = try await f.create("Exact values")
        var draft = original.content
        draft.details = ["amount": .number(Decimal(string: "1234567890123456789.123456789")!)]
        let fields = try BugPresentation.fields(before: original.content, after: draft)
        XCTAssertTrue(fields.first(where: { $0.id == "details" })?.after.contains("1234567890123456789.123456789") == true)
        draft.assessment = .observed; draft.rootBehavior = "Synthetic root"; draft.expectedBehavior = "Current expected"; draft.actualBehavior = "Observed actual"
        draft.sources.append(.init(scope: f.project.scope, origin: .observed, label: "User-attested observation", capturedAt: Date()))
        let editor = BugEditorModel(store: f.store, existing: original)
        try editor.applyJSON(BugPresentation.json(draft)); await editor.prepare()
        let result = await editor.publish(); XCTAssertEqual(result?.content.assessment, .observed)
        XCTAssertEqual(result?.content.sources, draft.sources)
        XCTAssertEqual(result?.content.details, draft.details)
    }

    func testIncomingPaginationPreservesSelectedHistoryWithoutDuplicates() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let target = try await f.create("Upstream")
        for index in 0..<51 {
            var draft = target.content; draft.title = "Synthetic reference \(index)"
            draft.relationships = [.init(kind: .relatedTo, target: target.id)]
            let proposal = try await f.store.prepare(draft, in: f.project.scope)
            _ = try await f.store.publishReviewed(proposal, in: f.project.scope)
        }
        let browser = ProjectBugsModel(project: f.project, open: { f.services })
        await browser.load(); XCTAssertEqual(browser.records.count, 50); XCTAssertTrue(browser.more)
        await browser.load(more: true); XCTAssertEqual(browser.records.count, 52); XCTAssertFalse(browser.more)
        await browser.select(target.id); XCTAssertEqual(browser.incoming.count, 50); XCTAssertTrue(browser.moreIncoming)
        await browser.loadMoreIncoming()
        XCTAssertEqual(browser.incoming.count, 51); XCTAssertEqual(Set(browser.incoming.map(\.id)).count, 51)
        XCTAssertEqual(browser.displayed?.id, target.id); XCTAssertFalse(browser.loadingIncoming); XCTAssertFalse(browser.moreIncoming)
    }
}
#endif
