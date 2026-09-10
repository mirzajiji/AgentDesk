import Foundation
import XCTest
@testable import AgentDeskCore

final class CityPayBugReportTests: XCTestCase {
    let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
    let environment = EnvironmentID()
    func context() throws -> CityPayReportContext { try .init(component: .backend, region: .uz, area: "Payments", module: "Refunds") }
    func draft() -> BugDraft {
        .init(title: "Negative amount accepted", sources: [.init(scope: scope, origin: .observed, label: "Synthetic", capturedAt: Date())],
            changeReason: "Reviewed", assessment: .observed, environment: environment,
            rootBehavior: "Refund creation accepts a negative amount", expectedBehavior: "Old prose must not supply current expectations",
            actualBehavior: "Refund SYN-REFUND-001 was created", reproduction: ["Submit supplied payload", "Inspect supplied response"],
            details: ["endpoint": .text("POST /synthetic/refunds"), "httpStatus": .number(201),
                      "payload": .object(["amount": .number(-1), "currency": .text("UZS")]), "persistedState": .boolean(true)])
    }
    func input(_ draft: BugDraft, current: Bool = true, stale: Bool = false) throws -> BugComparisonInput {
        let requirement = RequirementVersion(schemaVersion: 1, scope: scope, id: RequirementID(rawValue: "synthetic-refund")!,
            version: 2, supersedes: nil, previousFingerprint: nil, createdAt: Date(timeIntervalSince1970: 1000),
            content: .init(description: "Reject negative amounts without persistence.", changeReason: "Current", status: .active,
                expectedBehavior: ["persisted": .boolean(false)]))
        let links = current ? [BugRequirementReference(role: .affects, requirement: .init(id: requirement.id,
            version: stale ? 1 : 2, fingerprint: try requirement.fingerprint, historical: false))] : []
        return try .init(record: .init(schemaVersion: 1, scope: scope, id: BugID(), revision: 1, supersedes: nil,
            previousFingerprint: nil, createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000),
            content: draft, requirements: links), activeRequirements: current ? [requirement] : [])
    }
    func testReportUsesCurrentRequirementsAndPreservesSuppliedEvidenceWithoutInventingStatus() throws {
        let report = try CityPayBugReport.prepare(input(draft()), context: context())
        XCTAssertEqual(report.title, "[Backend - UZ] Payments - Refunds | Negative amount accepted")
        XCTAssertEqual(report.sections.map(\.name), [.environment, .description, .steps, .actual, .expected, .endpoint, .payload, .additional])
        let expected = try XCTUnwrap(report.sections.first { $0.name == .expected }).text
        XCTAssertTrue(expected.contains("synthetic-refund v2")); XCTAssertTrue(expected.contains("Reject negative amounts"))
        XCTAssertFalse(expected.contains("Old prose")); XCTAssertFalse(expected.contains("400")); XCTAssertFalse(expected.contains("201"))
        let actual = try XCTUnwrap(report.sections.first { $0.name == .actual }).text
        XCTAssertTrue(actual.contains("201")); XCTAssertTrue(actual.contains("SYN-REFUND-001")); XCTAssertTrue(actual.contains("true"))
        let payload = try XCTUnwrap(report.sections.first { $0.name == .payload }).text
        XCTAssertTrue(payload.contains("UZS")); XCTAssertTrue(payload.contains("-1"))
        XCTAssertFalse(report.sections.contains { $0.name.rawValue == "Impact" })
    }
    func testGroupingPreservesEachPayloadAndRejectsDifferentRootsOrAnchors() throws {
        var second = draft(); second.title = "Another invalid amount"; second.actualBehavior = "SYN-REFUND-002 created"
        second.details["payload"] = .object(["amount": .number(-2), "currency": .text("UZS")])
        let firstInput = try input(draft()), secondInput = try input(second)
        let grouped = try CityPayBugReport.prepareGroup([firstInput, secondInput], context: context(), problem: "Negative amounts accepted")
        XCTAssertEqual(grouped.groupedSources.map(\.id), [firstInput.record.id, secondInput.record.id])
        let actual = try XCTUnwrap(grouped.sections.first { $0.name == .actual }).text
        XCTAssertTrue(actual.contains("SYN-REFUND-001")); XCTAssertTrue(actual.contains("SYN-REFUND-002"))
        let payload = try XCTUnwrap(grouped.sections.first { $0.name == .payload }).text
        XCTAssertTrue(payload.contains("-1")); XCTAssertTrue(payload.contains("-2"))
        XCTAssertTrue(payload.contains(firstInput.record.id.rawValue)); XCTAssertTrue(payload.contains(secondInput.record.id.rawValue))
        second.rootBehavior = "Different cause"
        XCTAssertThrowsError(try CityPayBugReport.prepareGroup([firstInput, input(second)], context: context(), problem: "Do not combine"))
        second = draft(); second.details["endpoint"] = .text("GET /different")
        XCTAssertThrowsError(try CityPayBugReport.prepareGroup([firstInput, input(second)], context: context(), problem: "Do not combine"))
        XCTAssertThrowsError(try CityPayBugReport.prepareGroup([firstInput, firstInput], context: context(), problem: "Repeated source"))
    }

    func testMissingContextAndUnverifiedOrStaleFindingsFailClosed() throws {
        XCTAssertThrowsError(try CityPayReportContext(component: nil, region: .uz, area: "Payments", module: "Refunds"))
        XCTAssertThrowsError(try CityPayReportContext(component: .backend, region: nil, area: "Payments", module: "Refunds"))
        XCTAssertThrowsError(try CityPayBugReport.prepare(input(draft(), current: false), context: context()))
        XCTAssertThrowsError(try CityPayBugReport.prepare(input(draft(), stale: true), context: context()))
        var value = draft(); value.assessment = .reported
        XCTAssertThrowsError(try CityPayBugReport.prepare(input(value), context: context()))
        value.assessment = .blocked; value.relationships = [.init(kind: .blockedBy, target: BugID())]
        XCTAssertThrowsError(try CityPayBugReport.prepare(input(value), context: context()))
    }
    func testMissingActionsAndPersistenceRemainExplicitAndOptionalAPISectionsStayAbsent() throws {
        var value = draft(); value.reproduction = []; value.details = [:]
        let report = try CityPayBugReport.prepare(input(value), context: context())
        XCTAssertEqual(report.sections.first { $0.name == .steps }?.text, "Reproduction actions were not supplied.")
        XCTAssertTrue(report.sections.first { $0.name == .actual }?.text.contains("not supplied") == true)
        XCTAssertFalse(report.sections.contains { [.endpoint, .payload, .response].contains($0.name) })
    }
    func testConcurrencyAndStatusDetailsRetainExactLargeIdentifiersAndDistinctRequests() throws {
        var value = draft()
        value.details["requestA"] = .object(["id": .number(Decimal(string: "9007199254740993")!), "status": .text("Manual Review")])
        value.details["requestB"] = .object(["id": .text("SYN-B"), "status": .text("Rejected")])
        value.details["masterStatus"] = .text("Pending"); value.details["siblingChannel"] = .text("Not observed")
        let report = try CityPayBugReport.prepare(input(value), context: context())
        let additional = try XCTUnwrap(report.sections.first { $0.name == .additional }).text
        for expected in ["9007199254740993", "Manual Review", "SYN-B", "Rejected", "Pending", "Not observed"] { XCTAssertTrue(additional.contains(expected)) }
    }
}
