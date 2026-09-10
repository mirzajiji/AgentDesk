import Foundation
import XCTest
@testable import AgentDeskCore

final class BugComparisonTests: XCTestCase {
    let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
    let environment = EnvironmentID()
    func draft() -> BugDraft {
        .init(title: "Synthetic refund failure",
              sources: [.init(scope: scope, origin: .observed, label: "Synthetic observation", capturedAt: Date(timeIntervalSince1970: 1000))],
              changeReason: "Review", assessment: .observed, environment: environment,
              rootBehavior: "Refund validation rejects a valid amount", expectedBehavior: "Accept amount", actualBehavior: "Reject amount",
              details: ["endpoint": .text("POST /refunds"), "httpStatus": .number(422)])
    }
    func input(_ draft: BugDraft, scope: ProjectScope? = nil, linked: RequirementVersion? = nil,
               active: [RequirementVersion] = []) throws -> BugComparisonInput {
        let references = try linked.map { [BugRequirementReference(role: .affects, requirement: .init(id: $0.id, version: $0.version,
            fingerprint: try $0.fingerprint, historical: false))] } ?? []
        return try .init(record: .init(schemaVersion: 1, scope: scope ?? self.scope, id: BugID(), revision: 1,
            supersedes: nil, previousFingerprint: nil, createdAt: Date(timeIntervalSince1970: 1000), updatedAt: Date(timeIntervalSince1970: 1000),
            content: draft, requirements: references), activeRequirements: active)
    }
    func requirement(_ version: Int = 1, status: RequirementStatus = .active) -> RequirementVersion {
        .init(schemaVersion: 1, scope: scope, id: RequirementID(rawValue: "refund")!, version: version,
              supersedes: nil, previousFingerprint: nil, createdAt: Date(timeIntervalSince1970: 1000),
              content: .init(description: "Refund validation", changeReason: "Synthetic", status: status))
    }
    func testExactBehaviorMatchesDespiteDifferentTitlesRegistrationAndStatus() throws {
        let left = try input(draft()); var other = draft()
        other.title = "Different title"; other.status = .closed; other.ticket = try .init(key: "SYN-12")
        let right = try input(other)
        XCTAssertEqual(try BugComparison.fingerprint(left), try BugComparison.fingerprint(right))
        XCTAssertEqual(try BugComparison.compare(left, with: right).classification, .duplicate)
    }
    func testTitleAloneCannotCreateOverlap() throws {
        var other = draft(); other.rootBehavior = "Unrelated root"; other.expectedBehavior = "Different expectation"
        other.actualBehavior = "Different result"; other.details = ["endpoint": .text("GET /users")]
        XCTAssertEqual(try BugComparison.compare(input(draft()), with: input(other)).classification, .distinct)
    }
    func testCaseAndStructuredDifferencesRemainVisible() throws {
        let left = try input(draft()); var other = draft(); other.actualBehavior = "reject amount"
        var result = try BugComparison.compare(left, with: input(other))
        XCTAssertEqual(result.classification, .possibleDuplicate); XCTAssertTrue(result.differingFields.contains("actualBehavior"))
        other = draft(); other.details["httpStatus"] = .number(500)
        result = try BugComparison.compare(left, with: input(other))
        XCTAssertEqual(result.classification, .possibleDuplicate); XCTAssertTrue(result.differingFields.contains("httpStatus"))
    }
    func testUnknownAttributesAggregateAllDifferencesWithoutExposingKeys() throws {
        var first = draft(); first.details["a-private-key"] = .text("Same"); first.details["z-private-key"] = .text("Before")
        var second = first; second.details["z-private-key"] = .text("After")
        let result = try BugComparison.compare(input(first), with: input(second))
        XCTAssertEqual(result.classification, .possibleDuplicate)
        XCTAssertTrue(result.differingFields.contains("otherAttributes")); XCTAssertFalse(result.matchingFields.contains("otherAttributes"))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(result), as: UTF8.self).contains("private-key"))
    }
    func testBlockedReportedAndMissingEnvironmentCannotBeDuplicates() throws {
        let existing = try input(draft()); var value = draft(); value.assessment = .blocked
        value.relationships = [.init(kind: .blockedBy, target: BugID())]
        XCTAssertEqual(try BugComparison.compare(input(value), with: existing).classification, .blocked)
        value = draft(); value.assessment = .reported
        XCTAssertEqual(try BugComparison.compare(input(value), with: existing).classification, .needsEvidence)
        value = draft(); value.environment = nil
        XCTAssertEqual(try BugComparison.compare(input(value), with: existing).classification, .needsEnvironment)
        value = draft(); value.environment = EnvironmentID()
        XCTAssertEqual(try BugComparison.compare(input(value), with: existing).classification, .related)
    }
    func testStaleMissingAndRetiredRequirementResolutionFailsClosed() throws {
        let v1 = requirement(), v2 = requirement(2), existing = try input(draft(), linked: v2, active: [v2])
        for active in [[v2], []] {
            let stale = try input(draft(), linked: v1, active: active)
            XCTAssertTrue(stale.staleRequirements)
            XCTAssertEqual(try BugComparison.compare(stale, with: existing).classification, .needsRequirementReview)
            XCTAssertEqual(try BugComparison.compare(existing, with: stale).classification, .possibleDuplicate)
        }
        XCTAssertThrowsError(try input(draft(), linked: v1, active: [requirement(status: .retired)]))
        XCTAssertThrowsError(try input(draft(), active: [v1]), "Unlinked current versions cannot be injected")
    }
    func testExactGenericTextRequiresAComparisonAnchor() throws {
        var value = draft(); value.details = [:]
        XCTAssertEqual(try BugComparison.compare(input(value), with: input(value)).classification, .possibleDuplicate)
        let current = requirement()
        XCTAssertEqual(try BugComparison.compare(input(value, linked: current, active: [current]),
            with: input(value, linked: current, active: [current])).classification, .duplicate)
    }
    func testCrossProjectComparisonAndSelfComparisonAreRejected() throws {
        let incoming = try input(draft()), foreign = ProjectScope(workspaceID: scope.workspaceID, projectID: ProjectID())
        var value = draft(); value.sources = [.init(scope: foreign, origin: .observed, label: "Synthetic", capturedAt: Date())]
        XCTAssertThrowsError(try BugComparison.compare(incoming, with: input(value, scope: foreign)))
        XCTAssertThrowsError(try BugComparison.compare(incoming, with: incoming))
    }
    func testWhitespaceNormalizationDoesNotFlattenStructuredValues() throws {
        var value = draft(); value.rootBehavior = " \n" + value.rootBehavior + "\r\n"
        XCTAssertEqual(try BugComparison.compare(input(draft()), with: input(value)).classification, .duplicate)
        value = draft(); value.details["endpoint"] = .text("POST /refunds ")
        XCTAssertEqual(try BugComparison.compare(input(draft()), with: input(value)).classification, .possibleDuplicate)
    }
}
