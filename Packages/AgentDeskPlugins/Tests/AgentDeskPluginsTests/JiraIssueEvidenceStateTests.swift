import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraIssueEvidenceStateTests: XCTestCase {
    func testScopedStateIgnoresReadTimeAndJSONOrderingButTracksRevision() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let cloud = UUID()
        func evidence(_ json: String, cloudID: UUID? = nil, time: Double = 0, run: RunID? = nil) throws -> JiraIssueEvidence {
            let scope = RedactionContext(scope: context.scope, environmentID: context.environmentID, runID: run ?? context.runID)
            let content = try ContentRedactor(context: scope).redactJSON(json, in: scope)
            return JiraIssueEvidence(requestedIdentifier: "SYN-1", resolvedKey: "SYN-1", issueID: "123",
                cloudID: cloudID ?? cloud, observedAt: Date(timeIntervalSince1970: time), content: content)
        }
        let original = #"{"id":"123","key":"SYN-1","fields":{"updated":"2026-09-11T12:00:00Z","summary":"Before"}}"#
        let reordered = #"{"fields":{"summary":"Before","updated":"2026-09-11T12:00:00Z"},"key":"SYN-1","id":"123"}"#
        let snapshot = try JiraIssueSnapshot(evidence(original))
        let other = RedactionContext(scope: context.scope, environmentID: context.environmentID, runID: RunID())
        let foreign = try ContentRedactor(context: other).redactText("Foreign edit", in: other)
        XCTAssertThrowsError(try snapshot.edit(summary: foreign)) {
            XCTAssertEqual($0 as? AuthorizationError, .scopeMismatch)
        }
        let fingerprint = try evidence(original).editFingerprint()
        XCTAssertEqual(fingerprint, try evidence(reordered, time: 100).editFingerprint())
        XCTAssertNotEqual(fingerprint, try evidence(original, cloudID: UUID()).editFingerprint())
        XCTAssertNotEqual(fingerprint, try evidence(original, run: RunID()).editFingerprint())
        XCTAssertNotEqual(fingerprint, try evidence(original.replacingOccurrences(of: "12:00", with: "12:01")).editFingerprint())
        XCTAssertNotEqual(fingerprint, try evidence(original.replacingOccurrences(of: "Before", with: "After")).editFingerprint())
        for malformed in [#"{"id":"123","key":"SYN-1","fields":{}}"#,
                          #"{"id":"456","key":"SYN-1","fields":{"updated":"today"}}"#] {
            XCTAssertThrowsError(try evidence(malformed).editFingerprint())
        }
    }
}
