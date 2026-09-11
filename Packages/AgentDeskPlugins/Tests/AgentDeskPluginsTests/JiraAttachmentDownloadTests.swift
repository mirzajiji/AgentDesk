import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraAttachmentDownloadTests: XCTestCase {
    func testDownloadUsesGatewayWithoutRedirectAndChecksSiteAndSize() throws {
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-work"])
        let metadata = try metadata(cloudID: resource.id)
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 2000), scopes: ["read:jira-work"])
        let request = try JiraAttachmentDownload.make(metadata: metadata, resource: resource, tokens: tokens, now: Date(timeIntervalSince1970: 1000), maximumBytes: 4)
        XCTAssertEqual(request.url?.absoluteString, resource.apiOrigin.absoluteString + "/rest/api/3/attachment/content/123?redirect=false")
        XCTAssertThrowsError(try JiraAttachmentDownload.make(metadata: metadata, resource: .init(id: UUID(), scopes: ["read:jira-work"]), tokens: tokens, now: Date(timeIntervalSince1970: 1000), maximumBytes: 4))
        XCTAssertThrowsError(try JiraAttachmentDownload.make(metadata: metadata, resource: resource, tokens: tokens, now: Date(timeIntervalSince1970: 1000), maximumBytes: 3))
    }
    func testExactCompleteBytesRemainPrivateAndPartialResponsesFail() throws {
        let metadata = try metadata(cloudID: UUID())
        let result = try JiraAttachmentDownload.decode(.init(status: 200, body: Data("test".utf8)), metadata: metadata, maximumBytes: 4)
        XCTAssertEqual(result.withBytes { $0 }, Data("test".utf8))
        XCTAssertEqual(result.context, metadata.content.context)
        XCTAssertFalse(String(reflecting: result).contains("test"))
        for response in [JiraHTTPResponse(status: 206, body: Data("test".utf8)), .init(status: 200, body: Data("tes".utf8)), .init(status: 200, body: Data("tests".utf8)), .init(status: 303, body: Data())] {
            XCTAssertThrowsError(try JiraAttachmentDownload.decode(response, metadata: metadata, maximumBytes: 4))
        }
    }
    private func metadata(cloudID: UUID) throws -> JiraAttachmentMetadata {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        return try JiraAttachmentRead.decode(.init(status: 200, body: Data(#"{"id":"123","filename":"evidence.txt","size":4,"mimeType":"text/plain"}"#.utf8)), expectedID: "123", cloudID: cloudID, context: context, redactor: ContentRedactor(context: context))
    }
}
