import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraAttachmentReadTests: XCTestCase {
    func testMetadataIdentitySizeAndSensitiveFields() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let redactor = try ContentRedactor(context: context)
        func response(id: String = "123", size: Int64 = 42, name: String = "../evidence.txt") throws -> JiraHTTPResponse {
            .init(status: 200, body: try JSONSerialization.data(withJSONObject: ["id": id, "filename": name,
                "size": size, "mimeType": "text/plain", "content": "https://untrusted.example/content", "token": "synthetic-private"]))
        }
        let metadata = try JiraAttachmentRead.decode(response(), expectedID: "123", cloudID: UUID(), context: context, redactor: redactor)
        XCTAssertEqual(metadata.size, 42)
        XCTAssertFalse(metadata.content.text.contains("synthetic-private"))
        XCTAssertTrue(metadata.content.text.contains("evidence.txt"), "Filename remains evidence, not a save path")
        for invalid in [try response(id: "124"), try response(size: -1), try response(name: ""), try response(name: "a\n.txt")] {
            XCTAssertThrowsError(try JiraAttachmentRead.decode(invalid, expectedID: "123", cloudID: UUID(), context: context, redactor: redactor))
        }
    }
    func testRequestNeverUsesMetadataDownloadURL() throws {
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-work"])
        let tokens = try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
            expiresAt: Date(timeIntervalSince1970: 2000), scopes: ["read:jira-work"])
        let request = try JiraAttachmentRead.make(id: "123", resource: resource, tokens: tokens, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(request.url?.absoluteString, resource.apiOrigin.absoluteString + "/rest/api/3/attachment/123")
        for id in ["", "../123", "https://other.example", "123?redirect=true", "-1"] {
            XCTAssertThrowsError(try JiraAttachmentRead.make(id: id, resource: resource, tokens: tokens, now: Date(timeIntervalSince1970: 1000)))
        }
    }
}
