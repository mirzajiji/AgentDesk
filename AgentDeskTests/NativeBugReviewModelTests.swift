#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDesk
@testable import AgentDeskRuntime

@MainActor
final class NativeBugReviewModelTests: XCTestCase {
    func testReportAndTicketDraftsRequireCurrentEvidenceBeforeCopying() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.openReview(database: f.database, directory: f.root, configuration: f.configuration)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        let requirements = try await catalog.requirementStore(in: f.scope), requirementID = RequirementID(rawValue: "synthetic-rule")!
        let requirement = try await requirements.prepare(.init(description: "Accept a valid refund", changeReason: "Reviewed", status: .active), id: requirementID, expectedVersion: nil, in: f.scope)
        _ = try await requirements.publishReviewed(requirement, in: f.scope)
        var draft = BugDraft(title: "Synthetic refund", sources: [.init(scope: f.scope, origin: .observed, label: "Fixture", capturedAt: Date())],
            changeReason: "Reviewed", assessment: .observed, environment: f.configuration.environment.id,
            rootBehavior: "Valid refund rejected", expectedBehavior: "Accept", actualBehavior: "Reject", reproduction: ["Request synthetic refund"],
            details: ["endpoint": .text("POST /refunds"), "password": .text("synthetic-private-value")])
        let first = try await store.prepare(draft, requirements: [.init(requirement: .init(id: requirementID))], in: f.scope)
        let incoming = try await store.publishReviewed(first, in: f.scope)
        let model = NativeBugReviewModel(service: service, catalog: catalog, incomingID: incoming.id)
        await model.load()
        let presentation = try NativeBugReviewEvidence(XCTUnwrap(model.review))
        XCTAssertEqual(presentation.sources.first?.requirements.first?.id, requirementID)
        XCTAssertNotEqual(presentation.sources.first?.content.details["password"], .text("synthetic-private-value"))
        let context = try CityPayReportContext(component: .backend, region: .geo, area: "Payments", module: "Refunds")
        await model.prepareReport(context: context, groupedIDs: [], problem: nil)
        XCTAssertNotNil(model.draft)
        let report = try await model.validatedDraftText()
        XCTAssertTrue(report.contains("Expected Result")); XCTAssertFalse(report.contains("synthetic-private-value"))
        draft.ticket = try .init(key: "SYN-22")
        let second = try await store.prepare(draft, requirements: [.init(requirement: .init(id: requirementID))], in: f.scope)
        let existing = try await store.publishReviewed(second, in: f.scope)
        do { _ = try await model.validatedDraftText(); XCTFail("Changed registry draft copied") } catch { }
        XCTAssertNil(model.draft)
        await model.load(); XCTAssertTrue(model.review?.registeredCandidateIDs.contains(existing.id) == true)
        await model.prepareTicketAddition(existingID: existing.id)
        let ticket = try await model.validatedDraftText()
        XCTAssertTrue(ticket.contains("SYN-22")); XCTAssertFalse(ticket.contains("synthetic-private-value"))
        draft.ticket = try .init(key: "SYN-23")
        let edit = try await store.prepare(draft, id: existing.id, expectedRevision: 1, in: f.scope)
        _ = try await store.publishReviewed(edit, in: f.scope)
        do { _ = try await model.validatedDraftText(); XCTFail("Relinked ticket draft copied") } catch { }
        XCTAssertNil(model.draft)
        model.cancel(); await service.shutdown(); await f.remove()
    }

    func testReviewedDecisionAndStaleContextClearPresentation() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.openReview(database: f.database, directory: f.root, configuration: f.configuration)
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        let draft = BugDraft(title: "Synthetic", sources: [.init(scope: f.scope, origin: .observed, label: "Fixture", capturedAt: Date())],
            changeReason: "Reviewed", assessment: .observed, environment: f.configuration.environment.id,
            rootBehavior: "Synthetic callback", expectedBehavior: "Accept", actualBehavior: "Reject")
        let first = try await store.prepare(draft, in: f.scope), incoming = try await store.publishReviewed(first, in: f.scope)
        let second = try await store.prepare(draft, in: f.scope), existing = try await store.publishReviewed(second, in: f.scope)
        var contextValid = true
        var storageBusy = false
        let model = NativeBugReviewModel(service: service, catalog: catalog, incomingID: incoming.id,
            validateContext: {
                if storageBusy { throw CatalogError.busy }
                if !contextValid { throw ExecutionSetupError.staleContext }
            })
        await model.load(); XCTAssertEqual(model.review?.matches.count, 1)
        storageBusy = true
        await model.prepareResolution(existingID: existing.id, resolution: .duplicate, reason: "Reviewed same behavior")
        XCTAssertNil(model.decision)
        XCTAssertFalse(model.busy)
        XCTAssertTrue(model.error?.contains("storage is busy") == true)
        let afterBusy = try await store.history(incoming.id, in: f.scope)
        XCTAssertEqual(afterBusy.count, 1)
        storageBusy = false
        await model.prepareResolution(existingID: existing.id, resolution: .duplicate, reason: "Reviewed same behavior")
        XCTAssertNotNil(model.decision)
        await model.discardDecision(); XCTAssertNil(model.decision)
        let untouched = try await store.history(incoming.id, in: f.scope); XCTAssertEqual(untouched.count, 1)
        await model.prepareResolution(existingID: existing.id, resolution: .duplicate, reason: "Reviewed same behavior")
        await model.publishResolution(); XCTAssertNil(model.decision); XCTAssertNotNil(model.review)
        XCTAssertEqual(model.review?.recordedResolution(for: existing.id), .duplicate)
        let saved = try await store.record(incoming.id, in: f.scope)
        XCTAssertEqual(saved?.content.comparisonReview?.resolution, .duplicate)
        contextValid = false
        do { _ = try await model.currentReview(); XCTFail("Stale context accepted") } catch { }
        XCTAssertNil(model.review); XCTAssertNotNil(model.error)
        model.cancel(); XCTAssertNil(model.error)
        await service.shutdown(); await f.remove()
    }
}
#endif
