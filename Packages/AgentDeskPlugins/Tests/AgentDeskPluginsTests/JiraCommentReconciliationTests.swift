import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraCommentReconciliationTests: XCTestCase {
    func testExactBodyCandidatesPreserveAmbiguityAndPageContinuation() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let draft = try JiraCommentDraft(identifier: "SYN-1", content: redactor.redactText("Evidence", in: context))
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: draft.body) as? [String: Any])
        let body = try XCTUnwrap(payload["body"])
        let bytes = try JSONSerialization.data(withJSONObject: ["startAt": 0, "maxResults": 2, "total": 3,
            "comments": [["id": "1", "body": body], ["id": "2", "body": body]]])
        let page = try JiraCommentsRead.decode(.init(status: 200, body: bytes), expectedStart: 0, requestedLimit: 2, context: context, redactor: redactor)
        let candidates = try JiraCommentReconciliation.compare(draft, page: page)
        XCTAssertEqual(candidates.matchingIDs, ["1", "2"])
        XCTAssertEqual(candidates.inspectedCount, 2)
        XCTAssertEqual(candidates.nextStartAt, 2)
        let changed = try JiraCommentDraft(identifier: "SYN-1", content: redactor.redactText("Different", in: context))
        XCTAssertTrue(try JiraCommentReconciliation.compare(changed, page: page).matchingIDs.isEmpty)
        let foreignContext = RedactionContext(scope: context.scope, environmentID: context.environmentID, runID: RunID())
        let foreign = try JiraCommentDraft(identifier: "SYN-1", content: ContentRedactor(context: foreignContext).redactText("Evidence", in: foreignContext))
        XCTAssertThrowsError(try JiraCommentReconciliation.compare(foreign, page: page))
    }
}
