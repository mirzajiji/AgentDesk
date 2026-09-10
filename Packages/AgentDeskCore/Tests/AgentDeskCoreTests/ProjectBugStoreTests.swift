import Foundation
import Synchronization
import XCTest
@testable import AgentDeskCore

@MainActor
final class ProjectBugStoreTests: XCTestCase {
    struct Fixture {
        let container: URL, catalog: WorkspaceCatalog, scope: ProjectScope, store: ProjectBugStore, requirements: ProjectRequirementStore
        init(clock: @escaping @Sendable () -> Date = { Date() }) async throws {
            container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            catalog = try WorkspaceCatalog(container: container)
            let workspace = try await catalog.createWorkspace(name: "Synthetic bugs")
            scope = try await catalog.createProject(in: workspace.id, name: "Synthetic project").scope
            let root = try ConfigurationDirectory(trustedContainer: container), owner = try root.child(scope.workspaceID.rawValue)
            store = ProjectBugStore(scope: scope, root: root, workspace: owner, project: try owner.child("Projects").child(scope.projectID.rawValue), clock: clock)
            requirements = try await catalog.requirementStore(in: scope)
        }
        func remove() { try? FileManager.default.removeItem(at: container) }
        func folder(_ id: BugID) -> URL { container.appendingPathComponent("\(scope.workspaceID)/Projects/\(scope.projectID)/Memory/Bugs/\(id)") }
        func draft(_ title: String = "Synthetic bug") -> BugDraft {
            .init(title: title, sources: [.init(scope: scope, origin: .humanStatement, label: "Synthetic fixture", capturedAt: Date())], changeReason: "Reviewed")
        }
        func create(_ draft: BugDraft? = nil) async throws -> BugRecord {
            let proposal = try await store.prepare(draft ?? self.draft(), in: scope)
            return try await store.publishReviewed(proposal, in: scope)
        }
        func requirement(_ version: Int) async throws -> RequirementVersion {
            let proposal = try await requirements.prepare(.init(description: "Synthetic version \(version)", changeReason: "Reviewed", status: .active),
                id: RequirementID(rawValue: "refund-rule")!, expectedVersion: version == 1 ? nil : version - 1, in: scope)
            return try await requirements.publishReviewed(proposal, in: scope)
        }
    }

    func testReviewCancelAndTicketRelinkingPreserveImmutableHistoryAcrossReopen() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let cancelled = try await f.store.prepare(f.draft(), in: f.scope)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.folder(cancelled.candidate.id).path))
        await f.store.cancel(cancelled)
        do { _ = try await f.store.publishReviewed(cancelled, in: f.scope); XCTFail() } catch { XCTAssertEqual(error as? BugRegistryError, .invalidReview) }
        var current = try await f.create()
        let original = try Data(contentsOf: f.folder(current.id).appendingPathComponent("bug.v1.json"))
        for ticket in [try ExternalBugTicket(key: "B2C-1234"), try ExternalBugTicket(url: "https://issues.example.test/browse/B2C-2345"), nil] {
            var draft = current.content; draft.ticket = ticket; draft.changeReason = "Reviewed association change"
            let proposal = try await f.store.prepare(draft, id: current.id, expectedRevision: current.revision, in: f.scope)
            current = try await f.store.publishReviewed(proposal, in: f.scope)
        }
        let reopened = try await f.catalog.bugStore(in: f.scope)
        let history = try await reopened.history(current.id, in: f.scope)
        XCTAssertEqual(history.map(\.revision), [4, 3, 2, 1]); XCTAssertNil(history[0].content.ticket)
        XCTAssertEqual(history[1].content.ticket?.url, "https://issues.example.test/browse/B2C-2345")
        XCTAssertEqual(history[2].content.ticket?.key, "B2C-1234")
        XCTAssertEqual(try Data(contentsOf: f.folder(current.id).appendingPathComponent("bug.v1.json")), original)
        let registered = try await reopened.list(in: f.scope, registered: true); XCTAssertTrue(registered.isEmpty)
    }

    func testLatestRequirementIsBoundAtReviewAndOrdinaryEditsPreserveCreationReference() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let first = try await f.requirement(1)
        let pending = try await f.store.prepare(f.draft(), requirements: [.init(requirement: .init(id: first.id))], in: f.scope)
        _ = try await f.requirement(2)
        do { _ = try await f.store.publishReviewed(pending, in: f.scope); XCTFail("Changed requirement was published") }
        catch { XCTAssertEqual(error as? BugRegistryError, .unavailableReference) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.folder(pending.candidate.id).path))
        let next = try await f.store.prepare(f.draft(), requirements: [.init(requirement: .init(id: first.id))], in: f.scope)
        let bug = try await f.store.publishReviewed(next, in: f.scope)
        XCTAssertEqual(bug.requirements.first?.requirement.version, 2)
        _ = try await f.requirement(3)
        var draft = bug.content; draft.ticket = try ExternalBugTicket(key: "B2C-1234")
        let linked = try await f.store.prepare(draft, id: bug.id, expectedRevision: 1, in: f.scope)
        let updated = try await f.store.publishReviewed(linked, in: f.scope)
        XCTAssertEqual(updated.requirements, bug.requirements)
        let historical = try await f.store.prepare(f.draft(), requirements: [.init(role: .introducedBy, requirement: .init(id: first.id, historicalVersion: 1))], in: f.scope)
        XCTAssertEqual(historical.candidate.requirements.first?.requirement.version, 1)
        XCTAssertEqual(historical.candidate.requirements.first?.requirement.historical, true)
        await f.store.cancel(historical)
    }

    func testWrongScopeMissingReferencesAndRelationshipCyclesFailClosed() async throws {
        let f = try await Fixture(), other = try await Fixture(); defer { f.remove(); other.remove() }
        do { _ = try await f.store.prepare(f.draft(), in: other.scope); XCTFail() } catch { XCTAssertEqual(error as? BugRegistryError, .scopeMismatch) }
        let foreign = try await other.create()
        var draft = f.draft(); draft.relationships = [.init(kind: .relatedTo, target: foreign.id)]
        do { _ = try await f.store.prepare(draft, in: f.scope); XCTFail() } catch { XCTAssertEqual(error as? BugRegistryError, .unavailableReference) }
        let a = try await f.create()
        draft.relationships = [.init(kind: .blockedBy, target: a.id)]; draft.assessment = .blocked
        let b = try await f.create(draft)
        var cycle = a.content; cycle.relationships = [.init(kind: .blockedBy, target: b.id)]; cycle.assessment = .blocked
        do { _ = try await f.store.prepare(cycle, id: a.id, expectedRevision: 1, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? BugRegistryError, .invalidDocument) }
    }

    func testStaleReviewReplayExpiryAndCancellationWriteNoNewVersion() async throws {
        let clock = Mutex(Date()), f = try await Fixture(clock: { clock.withLock { $0 } }); defer { f.remove() }
        let bug = try await f.create()
        let first = try await f.store.prepare(bug.content, id: bug.id, expectedRevision: 1, in: f.scope)
        let stale = try await f.store.prepare(bug.content, id: bug.id, expectedRevision: 1, in: f.scope)
        _ = try await f.store.publishReviewed(first, in: f.scope)
        do { _ = try await f.store.publishReviewed(stale, in: f.scope); XCTFail() } catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
        do { _ = try await f.store.publishReviewed(first, in: f.scope); XCTFail() } catch { XCTAssertEqual(error as? BugRegistryError, .invalidReview) }
        let expired = try await f.store.prepare(bug.content, id: bug.id, expectedRevision: 2, in: f.scope)
        clock.withLock { $0 = $0.addingTimeInterval(301) }
        do { _ = try await f.store.publishReviewed(expired, in: f.scope); XCTFail() } catch { XCTAssertEqual(error as? BugRegistryError, .invalidReview) }
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await f.store.prepare(f.draft(), in: f.scope) }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let history = try await f.store.history(bug.id, in: f.scope); XCTAssertEqual(history.count, 2)
    }

    func testOrphanVersionsRemainUnadoptedAndHistoryTamperingIsDetected() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let bug = try await f.create(), orphan = f.folder(bug.id).appendingPathComponent("bug.v2.json")
        try Data("{}".utf8).write(to: orphan)
        let proposal = try await f.store.prepare(bug.content, id: bug.id, expectedRevision: 1, in: f.scope)
        let next = try await f.store.publishReviewed(proposal, in: f.scope)
        XCTAssertEqual(next.revision, 3); XCTAssertEqual(next.supersedes, 1)
        let history = try await f.store.history(bug.id, in: f.scope); XCTAssertEqual(history.map(\.revision), [3, 1])
        XCTAssertEqual(try Data(contentsOf: orphan), Data("{}".utf8))
        let original = f.folder(bug.id).appendingPathComponent("bug.v1.json")
        let text = try String(contentsOf: original, encoding: .utf8).replacingOccurrences(of: "Synthetic bug", with: "Tampered bug")
        try Data(text.utf8).write(to: original)
        do { _ = try await f.store.record(bug.id, in: f.scope); XCTFail() } catch { XCTAssertEqual(error as? BugRegistryError, .invalidDocument) }
    }

    func testScopedEnvironmentStatusRegistrationAndKeysetPaging() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let environment = EnvironmentID()
        var draft = f.draft(); draft.environment = environment; draft.ticket = try ExternalBugTicket(key: "B2C-9876")
        let registered = try await f.create(draft)
        _ = try await f.create(); draft.status = .archived; _ = try await f.create(draft)
        let filtered = try await f.store.list(in: f.scope, environment: environment, registered: true)
        XCTAssertEqual(filtered.map(\.id), [registered.id])
        let first = try await f.store.list(in: f.scope, limit: 1)
        let next = try await f.store.list(in: f.scope, after: XCTUnwrap(first.first?.id), limit: 1)
        XCTAssertEqual(next.count, 1); XCTAssertNotEqual(first.first?.id, next.first?.id)
        let other = try await f.store.list(in: f.scope, environment: EnvironmentID()); XCTAssertTrue(other.isEmpty)
        do { _ = try await f.store.list(in: f.scope, limit: 101); XCTFail() } catch { XCTAssertEqual(error as? BugRegistryError, .limitExceeded) }
    }

    func testSymlinkAndHardLinkedRegistryRecordsAreRejected() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let bug = try await f.create(), file = f.folder(bug.id).appendingPathComponent("bug.v1.json")
        let alias = f.container.appendingPathComponent("synthetic-alias.json")
        try FileManager.default.linkItem(at: file, to: alias)
        do { _ = try await f.store.record(bug.id, in: f.scope); XCTFail("Multiply linked record accepted") } catch { XCTAssertTrue(error is ScopedFileError) }
        try FileManager.default.removeItem(at: alias)
        let original = try Data(contentsOf: file)
        try FileManager.default.removeItem(at: file); try original.write(to: alias)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: alias)
        do { _ = try await f.store.record(bug.id, in: f.scope); XCTFail("Symlink record accepted") } catch { XCTAssertTrue(error is ScopedFileError) }
    }

    func testReviewTokensAreStoreBoundAndPendingReviewLimitDoesNotWriteFiles() async throws {
        let f = try await Fixture(); defer { f.remove() }
        var pending: [BugProposal] = []
        for _ in 0..<16 { pending.append(try await f.store.prepare(f.draft(), in: f.scope)) }
        do { _ = try await f.store.prepare(f.draft(), in: f.scope); XCTFail() } catch { XCTAssertEqual(error as? BugRegistryError, .limitExceeded) }
        let other = try await f.catalog.bugStore(in: f.scope)
        do { _ = try await other.publishReviewed(pending[0], in: f.scope); XCTFail() } catch { XCTAssertEqual(error as? BugRegistryError, .invalidReview) }
        await f.store.cancel(pending[0])
        let replacement = try await f.store.prepare(f.draft(), in: f.scope)
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await f.store.publishReviewed(replacement, in: f.scope) }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let records = try await f.store.list(in: f.scope); XCTAssertTrue(records.isEmpty)
        for proposal in pending { XCTAssertFalse(FileManager.default.fileExists(atPath: f.folder(proposal.candidate.id).path)) }
    }
}
