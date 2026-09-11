import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraCommentsReadTests: XCTestCase {
    func testPaginationAdvancesByReturnedCountAndRedactsContent() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let first = try JiraCommentsRead.decode(response(start: 0, total: 3, ids: ["1", "2"]), expectedStart: 0, requestedLimit: 2, context: context, redactor: redactor)
        XCTAssertEqual(first.nextStartAt, 2)
        XCTAssertFalse(first.content.text.contains("synthetic-private"))
        let last = try JiraCommentsRead.decode(response(start: 2, total: 3, ids: ["3"]), expectedStart: 2, requestedLimit: 2, context: context, redactor: redactor)
        XCTAssertNil(last.nextStartAt)
        let empty = try JiraCommentsRead.decode(response(start: 0, total: 0, ids: []), expectedStart: 0, requestedLimit: 2, context: context, redactor: redactor)
        XCTAssertNil(empty.nextStartAt)
        for invalid in [try response(start: 1, total: 3, ids: ["1"]), try response(start: 0, total: 3, ids: []),
                        try response(start: 0, total: 3, ids: ["1", "1"]), try response(start: 0, total: 0, ids: ["1"]),
                        try response(start: 0, total: 3, ids: ["../1"])] {
            XCTAssertThrowsError(try JiraCommentsRead.decode(invalid, expectedStart: 0, requestedLimit: 2, context: context, redactor: redactor))
        }
    }
    func testRequestHasBoundedPagingAndFixedCommentRoute() throws {
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-work"])
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 2000), scopes: ["read:jira-work"])
        let request = try JiraCommentsRead.make(identifier: "A-1", startAt: 2, limit: 2, resource: resource, tokens: tokens, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(request.url?.path, resource.apiOrigin.path + "/rest/api/3/issue/A-1/comment")
        XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems,
            [.init(name: "startAt", value: "2"), .init(name: "maxResults", value: "2"), .init(name: "orderBy", value: "created")])
        for (start, limit) in [(-1, 2), (0, 0), (0, 101), (1_000_001, 2)] {
            XCTAssertThrowsError(try JiraCommentsRead.make(identifier: "A-1", startAt: start, limit: limit, resource: resource, tokens: tokens, now: Date(timeIntervalSince1970: 1000)))
        }
    }
    private func response(start: Int, total: Int, ids: [String]) throws -> JiraHTTPResponse {
        .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["startAt": start, "maxResults": 2, "total": total,
            "comments": ids.map { ["id": $0, "body": ["password": "synthetic-private"]] }]))
    }
}
