import Foundation
import XCTest
@testable import AgentDeskCore

final class BugRecordTests: XCTestCase {
    let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
    func draft(origin: MemorySource.Origin = .humanStatement) -> BugDraft {
        .init(title: "Synthetic defect", sources: [.init(scope: scope, origin: origin, label: "Synthetic observation", capturedAt: Date())], changeReason: "Reviewed")
    }
    func testManualRegistrationSupportsKeyURLOrBothAndRoundTrips() throws {
        for ticket in [try ExternalBugTicket(key: "B2C-1234"), try ExternalBugTicket(url: "https://issues.example.test/browse/B2C-1234"),
                       try ExternalBugTicket(key: "B2C-1234", url: "https://issues.example.test/browse/B2C-1234")] {
            XCTAssertEqual(try JSONDecoder().decode(ExternalBugTicket.self, from: JSONEncoder().encode(ticket)), ticket)
        }
        XCTAssertThrowsError(try ExternalBugTicket())
        for key in ["B2C-1234\n", " B2C-1234", "b2c-1234", "B2C-0", "../B2C-1234"] { XCTAssertThrowsError(try ExternalBugTicket(key: key)) }
    }
    func testTicketURLsRejectCredentialsExecutableSchemesAndSecretQueryStrings() throws {
        for url in ["javascript:alert(1)", "file:///private/data", "http://issues.example.test/browse/B2C-1",
                    "https://user:secret@issues.example.test/browse/B2C-1", "https://issues.example.test/?token=private",
                    "https://issues.example.test/#private", "https://issues.example.test/with space"] {
            XCTAssertThrowsError(try ExternalBugTicket(url: url), url)
            let bytes = try JSONSerialization.data(withJSONObject: ["url": url])
            XCTAssertThrowsError(try JSONDecoder().decode(ExternalBugTicket.self, from: bytes))
        }
    }
    func testReportedAndBlockedFindingsCannotBecomeObservedWithoutEvidenceBasis() throws {
        var reported = draft(); try reported.validate(in: scope)
        reported.assessment = .observed
        XCTAssertThrowsError(try reported.validate(in: scope))
        reported.rootBehavior = "Observed root"; reported.expectedBehavior = "Expected"; reported.actualBehavior = "Actual"
        XCTAssertThrowsError(try reported.validate(in: scope), "Human statement must not become observed merely by changing the assessment")
        var observed = draft(origin: .observed); observed.assessment = .observed
        observed.rootBehavior = "Root"; observed.expectedBehavior = "Expected"; observed.actualBehavior = "Actual"
        try observed.validate(in: scope)
        reported.assessment = .blocked
        XCTAssertThrowsError(try reported.validate(in: scope))
        reported.relationships = [.init(kind: .blockedBy, target: BugID())]
        try reported.validate(in: scope)
    }
    func testEvidenceAndSourcesCannotCrossProjectOrEnvironment() throws {
        var value = draft(); let environment = EnvironmentID(); value.environment = environment
        value.evidence = [.init(scope: scope, environment: environment, run: RunID(), agent: AgentID(), artifact: UUID(), sanitizedFingerprint: try .canonical("synthetic"))]
        try value.validate(in: scope)
        value.environment = EnvironmentID()
        XCTAssertThrowsError(try value.validate(in: scope))
        value = draft()
        value.sources = [.init(scope: .init(workspaceID: scope.workspaceID, projectID: ProjectID()), origin: .observed, label: "Foreign", capturedAt: Date())]
        XCTAssertThrowsError(try value.validate(in: scope))
    }
    func testSelfLinksDuplicateRelationshipsAndNonTestCoverageAreRejected() throws {
        let id = BugID(); var value = draft()
        value.relationships = [.init(kind: .duplicateOf, target: id)]
        XCTAssertThrowsError(try value.validate(in: scope, id: id))
        let link = BugRelationship(kind: .relatedTo, target: BugID())
        value.relationships = [link, link]
        XCTAssertThrowsError(try value.validate(in: scope, id: id))
        value.relationships = []
        value.coveredBy = [.init(kind: .bug, id: RequirementID(rawValue: "synthetic")!)]
        XCTAssertThrowsError(try value.validate(in: scope, id: id))
    }
    func testRecordRetainsFractionalProvenanceAndExactRequirementReferences() throws {
        let content = draft(), id = BugID(), date = Date(timeIntervalSinceReferenceDate: 1000.125)
        let reference = BugRequirementReference(role: .affects, requirement: TracedRequirement(id: RequirementID(rawValue: "refund")!,
            version: 3, fingerprint: try .canonical("Synthetic v3"), historical: false))
        let record = BugRecord(schemaVersion: 1, scope: scope, id: id, revision: 1, supersedes: nil, previousFingerprint: nil,
            createdAt: date, updatedAt: date, content: content, requirements: [reference])
        try record.validate()
        let restored = try JSONDecoder().decode(BugRecord.self, from: JSONEncoder().encode(record))
        XCTAssertEqual(restored, record); XCTAssertEqual(try restored.fingerprint, try record.fingerprint)
    }
}
