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

    func testRequirementImpactTracksCurrentStaleAndArchivedBugs() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let v1 = try await f.requirement(1)
        let proposal = try await f.store.prepare(f.draft(), requirements: [.init(requirement: .init(id: v1.id))], in: f.scope)
        let bug = try await f.store.publishReviewed(proposal, in: f.scope)
        let current = try await f.store.requirementImpact(of: v1.id, in: f.scope)
        XCTAssertEqual(current.links.map(\.record.id), [bug.id])
        XCTAssertEqual(current.links.map(\.status), [.current])
        _ = try await f.requirement(2)
        let stale = try await f.store.requirementImpact(of: v1.id, in: f.scope)
        XCTAssertEqual(stale.links.map(\.status), [.potentiallyStale])
        XCTAssertEqual(stale.links.first?.linked.requirement.version, 1)
        XCTAssertEqual(stale.links.first?.activeVersion, 2)
        let retirement = try await f.requirements.prepare(.init(description: "Retired rule", changeReason: "Review", status: .retired), id: v1.id, expectedVersion: 2, in: f.scope)
        _ = try await f.requirements.publishReviewed(retirement, in: f.scope)
        let unavailable = try await f.store.requirementImpact(of: v1.id, in: f.scope)
        XCTAssertEqual(unavailable.links.map(\.status), [.unavailable])
        XCTAssertNil(unavailable.links.first?.activeVersion)
        do {
            _ = try await f.store.requirementImpact(of: v1.id, in: .init(workspaceID: f.scope.workspaceID, projectID: ProjectID()))
            XCTFail("Foreign project accepted")
        } catch { }
        var draft = bug.content; draft.status = .archived
        let archive = try await f.store.prepare(draft, id: bug.id, expectedRevision: bug.revision, in: f.scope)
        _ = try await f.store.publishReviewed(archive, in: f.scope)
        let hidden = try await f.store.requirementImpact(of: v1.id, in: f.scope)
        XCTAssertTrue(hidden.links.isEmpty)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.store.requirementImpact(of: v1.id, in: f.scope)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled impact query accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testComparisonSnapshotIncludesArchivedAndRejectsChangesAfterCollection() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let environment = EnvironmentID(); var value = f.draft(); value.environment = environment
        value.status = .archived; value.ticket = try .init(key: "SYN-42")
        let archived = try await f.create(value)
        var other = value; other.environment = EnvironmentID(); _ = try await f.create(other)
        let snapshot = try await f.store.comparisonSnapshot(in: f.scope, environment: environment)
        XCTAssertEqual(snapshot.records.map { $0.record.id }, [archived.id])
        try await f.store.validate(snapshot, in: f.scope)
        _ = try await f.create(value)
        do { try await f.store.validate(snapshot, in: f.scope); XCTFail("New bugs must invalidate a prepared comparison") }
        catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
    }

    func testNativeSearchAndIncomingRelationshipsKeepScopeAndFilters() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let target = try await f.create()
        var draft = f.draft("Café callback")
        draft.ticket = try .init(key: "SYN-42"); draft.environment = EnvironmentID()
        draft.details = ["endpoint": .text("/synthetic/callback")]
        draft.relationships = [.init(kind: .blockedBy, target: target.id)]
        draft.assessment = .blocked
        let linked = try await f.create(draft)
        for query in ["CAFE", "syn-42", "/synthetic/callback", linked.id.rawValue] {
            let result = try await f.store.list(in: f.scope, environment: draft.environment, registered: true, query: query)
            XCTAssertEqual(result.map(\.id), [linked.id])
        }
        let incoming = try await f.store.list(in: f.scope, linkedTo: target.id)
        XCTAssertEqual(incoming.map(\.id), [linked.id])
        let unrelated = try await f.store.list(in: f.scope, linkedTo: linked.id); XCTAssertTrue(unrelated.isEmpty)
        let foreignEnvironment = try await f.store.list(in: f.scope, environment: EnvironmentID(), query: "CAFE")
        XCTAssertTrue(foreignEnvironment.isEmpty)
        do { _ = try await f.store.list(in: .init(workspaceID: f.scope.workspaceID, projectID: ProjectID()), query: "CAFE"); XCTFail() } catch { }
        draft.status = .archived
        let proposal = try await f.store.prepare(draft, id: linked.id, expectedRevision: 1, in: f.scope)
        _ = try await f.store.publishReviewed(proposal, in: f.scope)
        let hidden = try await f.store.list(in: f.scope, linkedTo: target.id); XCTAssertTrue(hidden.isEmpty)
        let archived = try await f.store.list(in: f.scope, statuses: Set(BugStatus.allCases), query: "cafe", linkedTo: target.id)
        XCTAssertEqual(archived.first?.revision, 2)
        do { _ = try await f.store.list(in: f.scope, query: String(repeating: "x", count: 1_025)); XCTFail() } catch { }
    }

    func testComparisonSnapshotResolvesLatestRequirementsAndDetectsRetirement() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let environment = EnvironmentID(), v1 = try await f.requirement(1)
        var value = f.draft(); value.environment = environment
        let proposal = try await f.store.prepare(value, requirements: [.init(requirement: .init(id: v1.id))], in: f.scope)
        _ = try await f.store.publishReviewed(proposal, in: f.scope)
        let initial = try await f.store.comparisonSnapshot(in: f.scope, environment: environment)
        XCTAssertFalse(try XCTUnwrap(initial.records.first).staleRequirements)
        _ = try await f.requirement(2)
        do { try await f.store.validate(initial, in: f.scope); XCTFail() } catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
        let updated = try await f.store.comparisonSnapshot(in: f.scope, environment: environment)
        XCTAssertTrue(try XCTUnwrap(updated.records.first).staleRequirements)
        XCTAssertEqual(updated.records.first?.activeRequirements.first?.version, 2)
        let retire = try await f.requirements.prepare(.init(description: "Retired", changeReason: "Synthetic", status: .retired),
            id: v1.id, expectedVersion: 2, in: f.scope)
        _ = try await f.requirements.publishReviewed(retire, in: f.scope)
        let retired = try await f.store.comparisonSnapshot(in: f.scope, environment: environment)
        XCTAssertTrue(try XCTUnwrap(retired.records.first).staleRequirements)
        XCTAssertTrue(try XCTUnwrap(retired.records.first).activeRequirements.isEmpty)
    }

    func testComparisonSnapshotRejectsForeignScopeAndCancelledReads() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let environment = EnvironmentID(), foreign = ProjectScope(workspaceID: f.scope.workspaceID, projectID: ProjectID())
        do { _ = try await f.store.comparisonSnapshot(in: foreign, environment: environment); XCTFail() } catch { }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.store.comparisonSnapshot(in: f.scope, environment: environment)
        }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testReviewedComparisonDecisionPersistsOverrideAndPreservesEarlierHistory() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let environment = EnvironmentID()
        let content = BugDraft(title: "Synthetic observed bug", sources: [.init(scope: f.scope, origin: .observed, label: "Synthetic", capturedAt: Date())],
            changeReason: "Reviewed", assessment: .observed, environment: environment,
            rootBehavior: "Root", expectedBehavior: "Expected", actualBehavior: "Actual", details: ["endpoint": .text("POST /synthetic")])
        let incoming = try await f.create(content), existing = try await f.create(content)
        let snapshot = try await f.store.comparisonSnapshot(in: f.scope, environment: environment)
        let decision = try await f.store.prepareComparisonDecision(snapshot, incomingID: incoming.id, existingID: existing.id,
            resolution: .distinct, reason: "Reviewed: separate incidents", in: f.scope)
        XCTAssertEqual(decision.candidate.content.comparisonReview?.suggested, .duplicate)
        XCTAssertEqual(decision.candidate.content.comparisonReview?.isOverride, true)
        let before = try await f.store.record(incoming.id, in: f.scope); XCTAssertEqual(before?.revision, 1)
        let saved = try await f.store.publishReviewed(decision, in: f.scope)
        XCTAssertEqual(saved.revision, 2); XCTAssertEqual(saved.content.comparisonReview?.existingRevision, 1)
        let reopened = try await f.catalog.bugStore(in: f.scope), history = try await reopened.history(incoming.id, in: f.scope)
        XCTAssertEqual(history.first?.content.comparisonReview?.resolution, .distinct)
        XCTAssertNil(history.last?.content.comparisonReview)
        var edit = saved.content; edit.title = "Updated title"
        let proposal = try await reopened.prepare(edit, id: incoming.id, expectedRevision: 2, in: f.scope)
        let edited = try await reopened.publishReviewed(proposal, in: f.scope)
        XCTAssertEqual(edited.content.comparisonReview, saved.content.comparisonReview)
    }

    func testPreparedComparisonDecisionRejectsChangedRegistryAtPublication() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let environment = EnvironmentID()
        let content = BugDraft(title: "Synthetic", sources: [.init(scope: f.scope, origin: .observed, label: "Synthetic", capturedAt: Date())],
            changeReason: "Reviewed", assessment: .observed, environment: environment,
            rootBehavior: "Root", expectedBehavior: "Expected", actualBehavior: "Actual", details: ["module": .text("Synthetic")])
        let incoming = try await f.create(content), existing = try await f.create(content)
        let snapshot = try await f.store.comparisonSnapshot(in: f.scope, environment: environment)
        let proposal = try await f.store.prepareComparisonDecision(snapshot, incomingID: incoming.id, existingID: existing.id,
            resolution: .duplicate, reason: "Reviewed same defect", in: f.scope)
        XCTAssertTrue(proposal.candidate.content.relationships.contains(.init(kind: .duplicateOf, target: existing.id)))
        _ = try await f.create(content)
        do { _ = try await f.store.publishReviewed(proposal, in: f.scope); XCTFail("Stale comparison published") }
        catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
        let retained = try await f.store.record(incoming.id, in: f.scope); XCTAssertEqual(retained?.revision, 1)
    }

    func testRequirementChangeInvalidatesDecisionAtPublicationWithoutChangingBugs() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let environment = EnvironmentID(), requirement = try await f.requirement(1)
        let content = BugDraft(title: "Synthetic", sources: [.init(scope: f.scope, origin: .observed, label: "Synthetic", capturedAt: Date())],
            changeReason: "Reviewed", assessment: .observed, environment: environment,
            rootBehavior: "Root", expectedBehavior: "Expected", actualBehavior: "Actual")
        let first = try await f.store.prepare(content, requirements: [.init(requirement: .init(id: requirement.id))], in: f.scope)
        let incoming = try await f.store.publishReviewed(first, in: f.scope)
        let second = try await f.store.prepare(content, requirements: [.init(requirement: .init(id: requirement.id))], in: f.scope)
        let existing = try await f.store.publishReviewed(second, in: f.scope)
        let snapshot = try await f.store.comparisonSnapshot(in: f.scope, environment: environment)
        let decision = try await f.store.prepareComparisonDecision(snapshot, incomingID: incoming.id, existingID: existing.id,
            resolution: .duplicate, reason: "Reviewed", in: f.scope)
        _ = try await f.requirement(2)
        do { _ = try await f.store.publishReviewed(decision, in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
        let retained = try await f.store.record(incoming.id, in: f.scope); XCTAssertEqual(retained?.revision, 1)
    }

    func testReportedFindingCannotBeOverriddenIntoVerifiedDuplicate() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let environment = EnvironmentID(); var value = f.draft(); value.environment = environment
        let incoming = try await f.create(value), existing = try await f.create(value)
        let snapshot = try await f.store.comparisonSnapshot(in: f.scope, environment: environment)
        do { _ = try await f.store.prepareComparisonDecision(snapshot, incomingID: incoming.id, existingID: existing.id,
            resolution: .duplicate, reason: "Override", in: f.scope); XCTFail() }
        catch { XCTAssertEqual(error as? BugRegistryError, .invalidReview) }
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
