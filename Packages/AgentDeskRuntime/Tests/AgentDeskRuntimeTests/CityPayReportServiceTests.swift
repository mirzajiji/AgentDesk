#if os(macOS)
import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class CityPayReportServiceTests: XCTestCase {
    func testReportRedactsStructuredSecretsBeforeProseAndRejectsDuplicateAndStaleDrafts() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let catalog = try WorkspaceCatalog(container: f.root), requirements = try await catalog.requirementStore(in: f.scope)
        let requirementID = RequirementID(rawValue: "synthetic-report-rule")!
        let requirement = try await requirements.prepare(.init(description: "Reject invalid amount", changeReason: "Synthetic", status: .active,
            expectedBehavior: ["password": .text("synthetic-requirement-secret"), "persisted": .boolean(false)]),
            id: requirementID, expectedVersion: nil, in: f.scope)
        _ = try await requirements.publishReviewed(requirement, in: f.scope)
        let store = try await catalog.bugStore(in: f.scope)
        let content = BugDraft(title: "Invalid amount accepted", sources: [.init(scope: f.scope, origin: .observed, label: "Synthetic", capturedAt: Date())],
            changeReason: "Reviewed", assessment: .observed, environment: f.configuration.environment.id,
            rootBehavior: "Invalid amount persisted", expectedBehavior: "Reject", actualBehavior: "Accepted",
            details: ["endpoint": .text("POST /synthetic"), "password": .text("synthetic-top-secret"),
                "payload": .object(["password": .text("synthetic-nested-secret"), "currency": .text("UZS")])])
        let first = try await store.prepare(content, requirements: [.init(requirement: .init(id: requirementID))], in: f.scope)
        let incoming = try await store.publishReviewed(first, in: f.scope)
        let review = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        let context = try CityPayReportContext(component: .backend, region: .uz, area: "Payments", module: "Refunds")
        let report = try await service.prepareCityPayReport(review, context: context)
        for secret in ["synthetic-requirement-secret", "synthetic-top-secret", "synthetic-nested-secret"] {
            XCTAssertFalse(report.content.text.contains(secret))
        }
        XCTAssertTrue(report.content.text.contains("UZS")); XCTAssertEqual(report.templateVersion, 1)
        try await service.validateCityPayReport(report)
        let second = try await store.prepare(content, requirements: [.init(requirement: .init(id: requirementID))], in: f.scope)
        let existing = try await store.publishReviewed(second, in: f.scope)
        let thirdProposal = try await store.prepare(content, requirements: [.init(requirement: .init(id: requirementID))], in: f.scope)
        let third = try await store.publishReviewed(thirdProposal, in: f.scope)
        do { try await service.validateCityPayReport(report); XCTFail("Changed registry did not invalidate report") }
        catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
        let duplicate = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        do { _ = try await service.prepareCityPayReport(duplicate, context: context); XCTFail("Duplicate became new-ticket draft") }
        catch { XCTAssertEqual(error as? CityPayReportError, .duplicateReviewRequired) }
        let grouped = try await service.prepareCityPayReport(duplicate, context: context, groupedIDs: [existing.id, third.id], problem: "Invalid amounts accepted")
        XCTAssertTrue(grouped.content.text.contains(existing.id.rawValue)); XCTAssertTrue(grouped.content.text.contains(third.id.rawValue))
        let decision = try await store.prepareComparisonDecision(duplicate.snapshot, incomingID: incoming.id, existingID: existing.id,
            resolution: .distinct, reason: "Reviewed separate incidents", in: f.scope)
        _ = try await store.publishReviewed(decision, in: f.scope)
        let partiallyResolved = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        do { _ = try await service.prepareCityPayReport(partiallyResolved, context: context); XCTFail("Other candidate ignored") }
        catch { XCTAssertEqual(error as? CityPayReportError, .duplicateReviewRequired) }
        let next = try await store.prepareComparisonDecision(partiallyResolved.snapshot, incomingID: incoming.id, existingID: third.id,
            resolution: .distinct, reason: "Reviewed another separate incident", in: f.scope)
        let saved = try await store.publishReviewed(next, in: f.scope)
        let resolved = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        XCTAssertEqual(resolved.decisions.count, 2)
        _ = try await service.prepareCityPayReport(resolved, context: context)
        var edited = saved.content; edited.title = "Edited finding"
        let edit = try await store.prepare(edited, id: incoming.id, expectedRevision: saved.revision, in: f.scope)
        _ = try await store.publishReviewed(edit, in: f.scope)
        let changed = try await service.prepareBugReview(catalog: catalog, incomingID: incoming.id)
        XCTAssertTrue(changed.decisions.isEmpty)
        do { _ = try await service.prepareCityPayReport(changed, context: context); XCTFail("Old decisions survived ordinary edit") }
        catch { XCTAssertEqual(error as? CityPayReportError, .duplicateReviewRequired) }
        let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty, "Known report formatting must not require Codex")
        await service.shutdown(); await f.remove()
    }
}
#endif
