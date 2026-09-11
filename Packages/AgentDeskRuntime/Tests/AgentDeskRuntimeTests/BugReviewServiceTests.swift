#if os(macOS)
import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class BugReviewServiceTests: XCTestCase {
    func draft(_ f: RunCoordinatorTests.Fixture) -> BugDraft {
        .init(title: "Synthetic refund", sources: [.init(scope: f.scope, origin: .observed, label: "Manual synthetic observation", capturedAt: Date())],
            changeReason: "Reviewed", assessment: .observed, environment: f.configuration.environment.id,
            rootBehavior: "Valid refund rejected", expectedBehavior: "Accept", actualBehavior: "Reject",
            details: ["endpoint": .text("POST /refunds"), "password": .text("synthetic-private-value")])
    }
    func save(_ draft: BugDraft, to store: ProjectBugStore) async throws -> BugRecord {
        let proposal = try await store.prepare(draft, in: store.scope)
        return try await store.publishReviewed(proposal, in: store.scope)
    }
    func testReviewOnlyServiceReadsWithoutProviderAndCannotPrepareExecution() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.openReview(database: f.database, directory: f.root, configuration: f.configuration)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        let incoming = try await save(draft(f), to: store)
        let review = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        try await service.validateBugReview(review)
        XCTAssertEqual(review.incomingID, incoming.id)
        do {
            _ = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Cannot execute")
            XCTFail("Review-only service prepared an execution")
        } catch { XCTAssertTrue(error is AuthorizationError) }
        let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty)
        await service.shutdown(); await f.remove()
    }

    func testNativeDecisionReviewCancellationStalenessAndExactPublication() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.openReview(database: f.database, directory: f.root, configuration: f.configuration)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        let incoming = try await save(draft(f), to: store), existing = try await save(draft(f), to: store)
        let review = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        let cancelled = try await service.prepareBugDecision(review, existingID: existing.id, resolution: .distinct, reason: "Reviewed distinction")
        await service.cancelBugDecision(cancelled)
        do { _ = try await service.publishBugDecision(cancelled); XCTFail("Cancelled decision published") } catch { }
        let unchanged = try await store.history(incoming.id, in: f.scope); XCTAssertEqual(unchanged.count, 1)
        let stale = try await service.prepareBugDecision(review, existingID: existing.id, resolution: .duplicate, reason: "Same behavior")
        _ = try await save(draft(f), to: store)
        do { _ = try await service.publishBugDecision(stale); XCTFail("Changed registry accepted") }
        catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
        let current = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        let exact = try await service.prepareBugDecision(current, existingID: existing.id, resolution: .duplicate, reason: "Reviewed matching behavior")
        XCTAssertFalse(exact.content.text.contains("synthetic-private-value"))
        let published = try await service.publishBugDecision(exact)
        XCTAssertEqual(published.revision, 2)
        XCTAssertEqual(published.content.comparisonReview, exact.decision)
        XCTAssertEqual(published.content.relationships.first?.target, existing.id)
        do { _ = try await service.publishBugDecision(exact); XCTFail("Decision replay accepted") } catch { }
        await service.shutdown(); await f.remove()
    }

    func testAuthorizedReviewRedactsSourceDataAndInvalidatesOnRegistryChange() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        let incoming = try await save(draft(f), to: store)
        var known = draft(f); known.ticket = try .init(key: "SYN-18"); known.title = "Existing ticket"
        let existing = try await save(known, to: store)
        let review = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        XCTAssertEqual(review.matches.map(\.existingID), [existing.id])
        XCTAssertEqual(review.matches.first?.result.classification, .duplicate)
        XCTAssertFalse(review.content.text.contains("synthetic-private-value"))
        XCTAssertTrue(review.content.text.contains("SYN-18"))
        try await service.validateBugReview(review)
        _ = try await save(draft(f), to: store)
        do { try await service.validateBugReview(review); XCTFail("Stale review remained usable") }
        catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
        let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty, "Deterministic comparison must not invoke Codex")
        await service.shutdown()
        let other = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        do { try await other.validateBugReview(review); XCTFail("Review transferred between native services") }
        catch { XCTAssertEqual(error as? BugRegistryError, .scopeMismatch) }
        await other.shutdown()
        await f.remove()
    }

    func testAmbiguityUsesReviewedProviderRunWithExactSanitizedEvidence() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(disposition: .approval); await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        let incoming = try await save(draft(f), to: store)
        var other = draft(f); other.actualBehavior = "Reject only after retry"; _ = try await save(other, to: store)
        let review = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        XCTAssertEqual(review.matches.first?.result.classification, .possibleDuplicate)
        let prepared = try await service.prepareBugAmbiguity(review, instructions: f.instructions, configuration: f.configuration)
        let snapshot = try XCTUnwrap(prepared.bugReviewSnapshot)
        XCTAssertFalse(snapshot.contains("synthetic-private-value"))
        do { _ = try await service.start(prepared); XCTFail("Approval bypassed") } catch { }
        let before = await f.provider.requests; XCTAssertTrue(before.isEmpty)
        _ = try await service.review(prepared, approve: true, expectedSequence: XCTUnwrap(prepared.approval?.sequence))
        let execution = try await service.start(prepared), outcome = await execution.result()
        XCTAssertEqual(outcome.state, .completed)
        let requests = await f.provider.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(try XCTUnwrap(requests.first).task.contains(snapshot))
        let stored = try await store.record(incoming.id, in: f.scope)
        XCTAssertEqual(stored?.revision, 1, "Codex interpretation must not mutate the registry")
        await service.shutdown(); await f.remove()
    }

    func testExactComparisonDoesNotInvokeCodexAndChangedSourcesInvalidatePreparedAmbiguity() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        let incoming = try await save(draft(f), to: store), existing = try await save(draft(f), to: store)
        let exact = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        do { _ = try await service.prepareBugAmbiguity(exact, instructions: f.instructions, configuration: f.configuration); XCTFail() }
        catch { XCTAssertEqual(error as? BugRegistryError, .invalidReview) }
        var content = existing.content; content.actualBehavior = "Different observation"
        let proposal = try await store.prepare(content, id: existing.id, expectedRevision: 1, in: f.scope)
        _ = try await store.publishReviewed(proposal, in: f.scope)
        let current = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        let prepared = try await service.prepareBugAmbiguity(current, instructions: f.instructions, configuration: f.configuration)
        _ = try await save(draft(f), to: store)
        do { _ = try await service.start(prepared); XCTFail("Changed evidence dispatched") }
        catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
        let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty)
        _ = try await service.discard(prepared)
        await service.shutdown(); await f.remove()
    }

    func testTicketEvidenceUsesOnlySelectedFindingAndRejectsChangedTicket() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        let incoming = try await save(draft(f), to: store)
        var known = draft(f); known.ticket = try .init(key: "SYN-20")
        let existing = try await save(known, to: store)
        var third = draft(f); third.title = "Other candidate must not enter comment"; _ = try await save(third, to: store)
        let review = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        let evidence = try await service.prepareBugTicketEvidence(review, existingID: existing.id)
        XCTAssertEqual(evidence.ticket.key, "SYN-20")
        XCTAssertTrue(evidence.content.text.contains("Additional evidence for existing ticket SYN-20"))
        XCTAssertFalse(evidence.content.text.contains("synthetic-private-value"))
        XCTAssertFalse(evidence.content.text.contains(third.title))
        try await service.validateBugTicketEvidence(evidence)
        var edit = existing.content; edit.ticket = try .init(key: "SYN-21")
        let proposal = try await store.prepare(edit, id: existing.id, expectedRevision: 1, in: f.scope)
        _ = try await store.publishReviewed(proposal, in: f.scope)
        do { try await service.validateBugTicketEvidence(evidence); XCTFail("Relinked ticket accepted") }
        catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
        let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty)
        await service.shutdown(); await f.remove()
    }

    func testTicketDraftRequiresKnownTicketAndResolvedDuplicate() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        let incoming = try await save(draft(f), to: store), existing = try await save(draft(f), to: store)
        let noTicket = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        do { _ = try await service.prepareBugTicketEvidence(noTicket, existingID: existing.id); XCTFail() }
        catch { XCTAssertEqual(error as? BugRegistryError, .invalidReview) }
        var edit = existing.content; edit.ticket = try .init(key: "SYN-22"); edit.actualBehavior = "Different result"
        let proposal = try await store.prepare(edit, id: existing.id, expectedRevision: 1, in: f.scope)
        _ = try await store.publishReviewed(proposal, in: f.scope)
        let ambiguous = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        do { _ = try await service.prepareBugTicketEvidence(ambiguous, existingID: existing.id); XCTFail() }
        catch { XCTAssertEqual(error as? BugRegistryError, .invalidReview) }
        let decision = try await store.prepareComparisonDecision(ambiguous.snapshot, incomingID: incoming.id, existingID: existing.id,
            resolution: .duplicate, reason: "Reviewed same root with additional evidence", in: f.scope)
        _ = try await store.publishReviewed(decision, in: f.scope)
        let reviewed = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        let draft = try await service.prepareBugTicketEvidence(reviewed, existingID: existing.id)
        XCTAssertTrue(draft.content.text.contains("Explicit local duplicate review"))
        await service.shutdown(); await f.remove()
    }

    func testEmptyRegistryOfCandidatesStillReportsMissingObservation() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        var content = draft(f); content.assessment = .reported
        let incoming = try await save(content, to: store)
        let review = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        XCTAssertTrue(review.matches.isEmpty); XCTAssertEqual(review.readiness, .needsEvidence)
        XCTAssertTrue(review.content.text.contains("needsEvidence"))
        await service.shutdown(); await f.remove()
    }

    func testReviewBoundsAndCancellationFailExplicitly() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        var oversized = draft(f); oversized.rootBehavior = String(repeating: "x", count: 32_768)
        let large = try await save(oversized, to: store)
        do { _ = try await service.prepareBugReview(catalog: catalog, incomingID: large.id); XCTFail("Oversize packet silently truncated") }
        catch { XCTAssertEqual(error as? BugRegistryError, .limitExceeded) }
        let incoming = try await save(draft(f), to: store)
        for _ in 0..<32 { _ = try await save(draft(f), to: store) }
        do { _ = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id); XCTFail("Relevant candidates silently truncated") }
        catch { XCTAssertEqual(error as? BugRegistryError, .limitExceeded) }
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        }
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await service.shutdown(); await f.remove()
    }

    func testMissingEvidenceCannotBecomeAReviewedComparison() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        var content = draft(f)
        content.evidence = [.init(scope: f.scope, environment: f.configuration.environment.id, run: RunID(), agent: f.configuration.agentID,
            artifact: UUID(), sanitizedFingerprint: try .canonical("missing"))]
        let incoming = try await save(content, to: store)
        do { _ = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id); XCTFail("Missing artifact accepted") }
        catch { XCTAssertEqual(error as? RunCoordinatorError, .invalidPreparation) }
        await service.shutdown(); await f.remove()
    }

    func testReadDenialPrecedesRegistryAccessAndRevocationInvalidatesPreparedReview() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        let incoming = try await save(draft(f), to: store)
        let review = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        let prior = f.configuration.policy
        let denied = try PolicyDocument(level: .environment, workspaceID: f.scope.workspaceID, projectID: f.scope.projectID,
            environmentID: f.configuration.environment.id, rules: [])
        try await service.installPolicy(.init(workspace: prior.workspace, project: prior.project,
            environment: denied, environmentKind: prior.environmentKind))
        do { try await review.validate(); XCTFail("Revoked review accepted") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        do { _ = try await service.prepareBugReview(catalog: catalog, incomingID: BugID()); XCTFail() }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied, "Denial must precede even missing-record discovery") }
        await service.shutdown(); await f.remove()
    }
}
#endif
