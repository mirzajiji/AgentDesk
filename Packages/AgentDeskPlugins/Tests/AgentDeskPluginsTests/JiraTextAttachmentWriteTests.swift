import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraTextAttachmentWriteTests: XCTestCase {
    func testUploadHeadersBodyAndReceiptBinding() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let redactor = try ContentRedactor(context: context)
        let draft = try JiraTextAttachmentDraft(identifier: "SYN-1", filename: redactor.redactText("evidence.txt", in: context),
            content: redactor.redactText("abc", in: context))
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 2000), scopes: ["write:jira-work"])
        let resource = JiraCloudResource(id: UUID(), scopes: ["write:jira-work"])
        let request = try JiraAttachmentWrite.make(draft, resource: resource, tokens: tokens, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(request.httpBody, draft.body)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, resource.apiOrigin.path + "/rest/api/3/issue/SYN-1/attachments")
        XCTAssertEqual(request.value(forHTTPHeaderField: "X-Atlassian-Token"), "no-check")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "multipart/form-data; boundary=\(draft.boundary)")
        XCTAssertThrowsError(try JiraAttachmentWrite.make(draft, resource: resource, tokens: tokens, now: tokens.expiresAt))
        let denied = JiraCloudResource(id: resource.id, scopes: [])
        XCTAssertThrowsError(try JiraAttachmentWrite.make(draft, resource: denied, tokens: tokens, now: Date(timeIntervalSince1970: 1000)))
        let receipt = try JiraAttachmentWrite.decode(.init(status: 200, body: Data(#"[{"id":"123","filename":"evidence.txt","size":3}]"#.utf8)), draft: draft, redactor: redactor)
        XCTAssertEqual(receipt.id, "123")
        for body in ["[]", "{}", #"[{"id":"123","filename":"other.txt","size":3}]"#, #"[{"id":"123","filename":"evidence.txt","size":4}]"#] {
            XCTAssertThrowsError(try JiraAttachmentWrite.decode(.init(status: 200, body: Data(body.utf8)), draft: draft, redactor: redactor)) {
                XCTAssertEqual($0 as? JiraMutationError, .outcomeUnknown)
            }
        }
        XCTAssertThrowsError(try JiraAttachmentWrite.decode(.init(status: 503, body: Data()), draft: draft, redactor: redactor)) {
            XCTAssertEqual($0 as? JiraMutationError, .outcomeUnknown)
        }
        XCTAssertThrowsError(try JiraAttachmentWrite.decode(.init(status: 413, body: Data()), draft: draft, redactor: redactor)) {
            XCTAssertEqual($0 as? JiraMutationError, .rejected(status: 413))
        }
    }
}
