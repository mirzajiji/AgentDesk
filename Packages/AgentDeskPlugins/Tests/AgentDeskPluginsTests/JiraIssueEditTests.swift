import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraIssueEditTests: XCTestCase {
    func testExactReplacementRequiresBothWriteGrantsAndFreshCredentials() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let draft = try JiraIssueEditDraft(identifier: "SYN-1", summary: redactor.redactText("Reviewed summary", in: context),
                                           expectedIssue: .canonical("observed state"))
        for tokenWrite in [true, false] {
            for siteWrite in [true, false] {
                let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
                    expiresAt: Date(timeIntervalSince1970: 2000), scopes: [tokenWrite ? "write:jira-work" : "read:jira-work"])
                let resource = JiraCloudResource(id: UUID(), scopes: [siteWrite ? "write:jira-work" : "read:jira-work"])
                if tokenWrite && siteWrite {
                    let request = try JiraIssueEdit.make(draft, resource: resource, tokens: tokens, now: Date(timeIntervalSince1970: 1000))
                    XCTAssertEqual(request.httpMethod, "PUT")
                    XCTAssertEqual(request.httpBody, draft.body)
                    XCTAssertEqual(request.url?.path, resource.apiOrigin.path + "/rest/api/3/issue/SYN-1")
                    XCTAssertNil(request.url?.query)
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
                } else {
                    XCTAssertThrowsError(try JiraIssueEdit.make(draft, resource: resource, tokens: tokens, now: Date(timeIntervalSince1970: 1000))) {
                        XCTAssertEqual($0 as? JiraServiceError, .accessDenied)
                    }
                }
                XCTAssertThrowsError(try JiraIssueEdit.make(draft, resource: resource, tokens: tokens, now: Date(timeIntervalSince1970: 2000)))
            }
        }
    }

    func testOnlyExpectedAcknowledgmentIsConfirmed() throws {
        XCTAssertNoThrow(try JiraIssueEdit.validateAcknowledgment(.init(status: 204, body: Data())))
        for status in [200, 201, 202, 301, 500, 503] {
            XCTAssertThrowsError(try JiraIssueEdit.validateAcknowledgment(.init(status: status, body: Data()))) {
                XCTAssertEqual($0 as? JiraMutationError, .outcomeUnknown)
            }
        }
        XCTAssertThrowsError(try JiraIssueEdit.validateAcknowledgment(.init(status: 204, body: Data("unexpected".utf8)))) {
            XCTAssertEqual($0 as? JiraMutationError, .outcomeUnknown)
        }
        for status in [400, 401, 403, 404, 409, 413, 422, 429] {
            XCTAssertThrowsError(try JiraIssueEdit.validateAcknowledgment(.init(status: status, body: Data()))) {
                XCTAssertEqual($0 as? JiraMutationError, .rejected(status: status))
            }
        }
    }
}
