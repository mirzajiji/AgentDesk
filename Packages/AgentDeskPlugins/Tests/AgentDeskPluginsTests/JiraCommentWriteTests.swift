import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraCommentWriteTests: XCTestCase {
    func testWriteRequiresBothWriteGrantsAndUsesExactDraftBody() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let draft = try JiraCommentDraft(identifier: "A-1", content: redactor.redactText("Observed evidence", in: context))
        for tokenWrite in [true, false] {
            for siteWrite in [true, false] {
                let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
                    expiresAt: Date(timeIntervalSince1970: 2000), scopes: [tokenWrite ? "write:jira-work" : "read:jira-work"])
                let resource = JiraCloudResource(id: UUID(), scopes: [siteWrite ? "write:jira-work" : "read:jira-work"])
                do {
                    let request = try JiraCommentWrite.make(draft, resource: resource, tokens: tokens, now: Date(timeIntervalSince1970: 1000))
                    XCTAssertTrue(tokenWrite && siteWrite)
                    XCTAssertEqual(request.httpMethod, "POST")
                    XCTAssertEqual(request.httpBody, draft.body)
                    XCTAssertEqual(request.url?.path, resource.apiOrigin.path + "/rest/api/3/issue/A-1/comment")
                    XCTAssertNil(request.url?.query)
                } catch { XCTAssertFalse(tokenWrite && siteWrite) }
                XCTAssertThrowsError(try JiraCommentWrite.make(draft, resource: resource, tokens: tokens, now: Date(timeIntervalSince1970: 2000)))
            }
        }
    }
    func testConfirmedReceiptIsRedactedAndAmbiguousResponsesStayUnknown() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let receipt = try JiraCommentWrite.decode(.init(status: 201, body: Data(#"{"id":"123","password":"synthetic-private"}"#.utf8)), context: context, redactor: redactor)
        XCTAssertEqual(receipt.id, "123")
        XCTAssertFalse(receipt.content.text.contains("synthetic-private"))
        for status in [200, 202, 204, 301, 500, 503] {
            XCTAssertThrowsError(try JiraCommentWrite.decode(.init(status: status, body: Data()), context: context, redactor: redactor)) {
                XCTAssertEqual($0 as? JiraMutationError, .outcomeUnknown)
            }
        }
        for body in ["{}", #"{"id":"../123"}"#, "not-json"] {
            XCTAssertThrowsError(try JiraCommentWrite.decode(.init(status: 201, body: Data(body.utf8)), context: context, redactor: redactor)) {
                XCTAssertEqual($0 as? JiraMutationError, .outcomeUnknown)
            }
        }
        for status in [400, 401, 403, 404, 413, 429] {
            XCTAssertThrowsError(try JiraCommentWrite.decode(.init(status: status, body: Data()), context: context, redactor: redactor)) {
                XCTAssertEqual($0 as? JiraMutationError, .rejected(status: status))
            }
        }
    }
}
