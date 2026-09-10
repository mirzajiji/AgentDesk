import Foundation
import Synchronization
import XCTest
@testable import AgentDeskCore

@MainActor
final class ProjectMemoryStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL, catalog: WorkspaceCatalog, scope: ProjectScope, store: ProjectMemoryStore
        let environment = EnvironmentID()
        var projectRoot: URL { root.appendingPathComponent("\(scope.workspaceID)/Projects/\(scope.projectID)") }
        init(clock: (@Sendable () -> Date)? = nil) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic memory")
            let project = try await catalog.createProject(in: workspace.id, name: "Synthetic project")
            scope = project.scope
            if let clock {
                let descriptor = try ConfigurationDirectory(trustedContainer: root)
                let owner = try descriptor.child(workspace.id.rawValue)
                store = ProjectMemoryStore(scope: scope, root: descriptor, workspace: owner,
                    project: try owner.child("Projects").child(project.id.rawValue), clock: clock)
            } else { store = try await catalog.memoryStore(in: scope) }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func draft(_ kind: MemoryKind = .inbox) -> MemoryDraft {
            MemoryDraft(kind: kind, topic: kind == .confirmed ? .architecture : .unclassified,
                title: "Synthetic finding", body: "A statement awaiting classification.",
                sources: [.init(scope: scope, origin: .interpretation, label: "Synthetic analysis",
                    environment: environment, run: RunID(), agent: AgentID(), capturedAt: Date(timeIntervalSince1970: 1_000))],
                structured: ["result": .object(["observed": .boolean(false)])], changeReason: "Synthetic intake")
        }
        func directory(_ id: MemoryID) -> URL { projectRoot.appendingPathComponent("Memory/Knowledge/\(id)") }
        func review(_ draft: MemoryDraft, id: MemoryID? = nil, expected: Int? = nil) async throws -> MemoryRecord {
            let proposal = try await store.prepare(draft, id: id, expectedRevision: expected, in: scope)
            return try await store.publishReviewed(proposal, in: scope)
        }
    }

    func testNativeSearchFindsCurrentFieldsWithScopeEnvironmentAndInactiveFilters() async throws {
        let f = try await Fixture(); defer { f.remove() }
        var value = f.draft(.note); value.title = "Café response"; value.body = "Exact synthetic phrase"
        value.tags = ["regression"]; value.structured = ["endpoint": .text("/synthetic/refunds")]
        value.environmentScope = [f.environment]
        let record = try await f.review(value)
        for query in ["CAFE", "synthetic phrase", "regression", "/synthetic/refunds"] {
            let matches = try await f.store.list(in: f.scope, environment: f.environment, query: query)
            XCTAssertEqual(matches.map(\.id), [record.id])
        }
        let differentEnvironment = try await f.store.list(in: f.scope, environment: EnvironmentID(), query: "cafe")
        XCTAssertTrue(differentEnvironment.isEmpty)
        value.disposition = .archived
        _ = try await f.review(value, id: record.id, expected: 1)
        let active = try await f.store.list(in: f.scope, query: "cafe"); XCTAssertTrue(active.isEmpty)
        let archived = try await f.store.list(in: f.scope, includeInactive: true, query: "cafe")
        XCTAssertEqual(archived.first?.revision, 2)
        do { _ = try await f.store.list(in: f.scope, query: String(repeating: "x", count: 1_025)); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .limitExceeded) }
    }

    func testCaptureCannotConfirmKnowledgeAndReviewedPromotionPreservesHistory() async throws {
        let f = try await Fixture(); defer { f.remove() }
        do { _ = try await f.store.capture(f.draft(.confirmed), in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        let first = try await f.store.capture(f.draft(), in: f.scope)
        let firstBytes = try Data(contentsOf: f.directory(first.id).appendingPathComponent("entry.v1.json"))
        var draft = first.content; draft.kind = .confirmed; draft.topic = .architecture; draft.changeReason = "Reviewed and confirmed"
        let second = try await f.review(draft, id: first.id, expected: 1)
        XCTAssertEqual(second.revision, 2); XCTAssertEqual(second.previousFingerprint, try first.fingerprint)
        XCTAssertEqual(second.content.sources.first?.origin, .interpretation, "Confirmation must not relabel the original source as observed")
        XCTAssertEqual(try Data(contentsOf: f.directory(first.id).appendingPathComponent("entry.v1.json")), firstBytes)
        let reopened = try await f.catalog.memoryStore(in: f.scope)
        let history = try await reopened.history(first.id, in: f.scope)
        XCTAssertEqual(history.map(\.content.kind), [.confirmed, .inbox]); XCTAssertEqual(history.last, first)
    }

    func testSubsecondSourceTimeAndStructuredValuesSurviveRoundTrip() async throws {
        let f = try await Fixture(); defer { f.remove() }
        var draft = f.draft(.note)
        draft.sources = [.init(scope: f.scope, origin: .observed, label: "Synthetic timestamp",
            capturedAt: Date(timeIntervalSinceReferenceDate: 812_345_678.1234567))]
        draft.structured = ["id": .number(Decimal(string: "9007199254740993")!), "values": .array([.null, .boolean(true)])]
        let saved = try await f.store.capture(draft, in: f.scope)
        let loaded = try await f.store.record(saved.id, in: f.scope)
        XCTAssertEqual(loaded?.content, draft); XCTAssertEqual(loaded, saved)
    }

    func testCancelledStaleAndReplayedReviewsCannotWriteChanges() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let cancelled = try await f.store.prepare(f.draft(.confirmed), in: f.scope)
        await f.store.cancel(cancelled)
        do { _ = try await f.store.publishReviewed(cancelled, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.directory(cancelled.candidate.id).path))
        let first = try await f.store.capture(f.draft(.note), in: f.scope)
        let a = try await f.store.prepare(first.content, id: first.id, expectedRevision: 1, in: f.scope)
        let b = try await f.store.prepare(first.content, id: first.id, expectedRevision: 1, in: f.scope)
        _ = try await f.store.publishReviewed(a, in: f.scope)
        do { _ = try await f.store.publishReviewed(b, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .staleVersion) }
        do { _ = try await f.store.publishReviewed(a, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
    }

    func testClassificationEnvironmentPaginationAndIgnoreFiltering() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let inbox = try await f.store.capture(f.draft(), in: f.scope)
        let note = try await f.store.capture(f.draft(.note), in: f.scope)
        var confirmed = f.draft(.confirmed); confirmed.environmentScope = [f.environment]
        _ = try await f.review(confirmed)
        let page = try await f.store.list(in: f.scope, limit: 1)
        let next = try await f.store.list(in: f.scope, after: try XCTUnwrap(page.first?.id), limit: 2)
        XCTAssertEqual(Set((page + next).map(\.id)).count, 3)
        let active = try await f.store.list(in: f.scope, kinds: [.confirmed], environment: f.environment)
        XCTAssertEqual(active.count, 1)
        let excluded = try await f.store.list(in: f.scope, kinds: [.confirmed], environment: EnvironmentID())
        XCTAssertTrue(excluded.isEmpty)
        var ignored = inbox.content; ignored.disposition = .ignored; ignored.changeReason = "User ignored import"
        _ = try await f.review(ignored, id: inbox.id, expected: 1)
        let pending = try await f.store.list(in: f.scope, kinds: [.inbox]); XCTAssertTrue(pending.isEmpty)
        var archive = note.content; archive.disposition = .archived; archive.changeReason = "Reviewed archive"
        _ = try await f.review(archive, id: note.id, expected: 1)
        let notes = try await f.store.list(in: f.scope, kinds: [.note]); XCTAssertTrue(notes.isEmpty)
        let all = try await f.store.list(in: f.scope, includeInactive: true); XCTAssertEqual(all.count, 3)
    }

    func testForeignProvenanceScopeAndProposalAreRejected() async throws {
        let f = try await Fixture(), other = try await Fixture(); defer { f.remove(); other.remove() }
        do { _ = try await f.store.capture(other.draft(), in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .scopeMismatch) }
        do { _ = try await f.store.list(in: other.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .scopeMismatch) }
        let proposal = try await f.store.prepare(f.draft(.confirmed), in: f.scope)
        do { _ = try await other.store.publishReviewed(proposal, in: other.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        let otherRecords = try await other.store.list(in: other.scope); XCTAssertTrue(otherRecords.isEmpty)
    }

    func testExpiredReviewCancelledTaskAndInvalidMetadataPreserveStorage() async throws {
        let now = Mutex(Date(timeIntervalSince1970: 1_000))
        let f = try await Fixture(clock: { now.withLock { $0 } }); defer { f.remove() }
        let proposal = try await f.store.prepare(f.draft(.confirmed), in: f.scope)
        now.withLock { $0 = Date(timeIntervalSince1970: 1_301) }
        do { _ = try await f.store.publishReviewed(proposal, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidReview) }
        var invalid = f.draft(.note); invalid.disposition = .ignored
        do { _ = try await f.store.capture(invalid, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidDocument) }
        let task = Task { try Task.checkCancellation(); return try await f.store.capture(f.draft(), in: f.scope) }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let all = try await f.store.list(in: f.scope); XCTAssertTrue(all.isEmpty)
    }

    func testInterruptedPublicationOrphanIsNotAdoptedOrOverwritten() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let first = try await f.store.capture(f.draft(), in: f.scope)
        let folder = f.directory(first.id), orphan = folder.appendingPathComponent("entry.v2.json")
        let original = Data("Synthetic incomplete orphan".utf8); try original.write(to: orphan)
        let second = try await f.review(first.content, id: first.id, expected: 1)
        XCTAssertEqual(second.revision, 3); XCTAssertEqual(second.supersedes, 1)
        let history = try await f.store.history(first.id, in: f.scope); XCTAssertEqual(history.map(\.revision), [3, 1])
        XCTAssertEqual(try Data(contentsOf: orphan), original)
    }

    func testHistoryTamperingAndSymlinkOrHardlinkVersionsFailClosed() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let first = try await f.store.capture(f.draft(), in: f.scope)
        let path = f.directory(first.id).appendingPathComponent("entry.v1.json"), original = try Data(contentsOf: path)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        object["revision"] = 2; try JSONSerialization.data(withJSONObject: object).write(to: path)
        do { _ = try await f.store.record(first.id, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? RequirementError, .invalidDocument) }
        try FileManager.default.removeItem(at: path)
        let external = f.root.appendingPathComponent("synthetic-external.json"); try original.write(to: external)
        try FileManager.default.createSymbolicLink(at: path, withDestinationURL: external)
        do { _ = try await f.store.record(first.id, in: f.scope); XCTFail() } catch { XCTAssertTrue(error is ScopedFileError) }
        try FileManager.default.removeItem(at: path); try FileManager.default.linkItem(at: external, to: path)
        do { _ = try await f.store.record(first.id, in: f.scope); XCTFail() } catch { XCTAssertTrue(error is ScopedFileError) }
    }
}
