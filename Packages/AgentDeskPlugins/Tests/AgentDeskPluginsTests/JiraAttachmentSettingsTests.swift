import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraAttachmentSettingsTests: XCTestCase {
    func testSettingsRequireTypedBoundedResponseAndPreserveScope() throws {
        let context = RedactionContext(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let cloud = UUID(), now = Date(timeIntervalSince1970: 1000)
        func decode(_ json: String, status: Int = 200) throws -> JiraAttachmentSettings {
            try JiraAttachmentSettingsRead.decode(.init(status: status, body: Data(json.utf8)), context: context, cloudID: cloud, observedAt: now)
        }
        let settings = try decode(#"{"enabled":true,"uploadLimit":4,"ignored":"private remote text"}"#)
        XCTAssertEqual(settings.context, context)
        XCTAssertEqual(settings.cloudID, cloud)
        XCTAssertEqual(settings.observedAt, now)
        XCTAssertTrue(settings.permitsSize(4))
        XCTAssertFalse(settings.permitsSize(5))
        XCTAssertFalse(settings.permitsSize(-1))
        XCTAssertFalse(try decode(#"{"enabled":false,"uploadLimit":4}"#).permitsSize(1))
        for json in ["{}", #"{"enabled":1,"uploadLimit":4}"#, #"{"enabled":true,"uploadLimit":-1}"#,
                     #"{"enabled":true,"uploadLimit":1.5}"#, #"{"enabled":true,"uploadLimit":"4"}"#,
                     String(repeating: " ", count: 16_385)] {
            XCTAssertThrowsError(try decode(json))
        }
        XCTAssertThrowsError(try decode(#"{"enabled":true,"uploadLimit":4}"#, status: 403))
        XCTAssertThrowsError(try decode(#"{"enabled":true,"uploadLimit":4}"#, status: 204))
    }

    func testRequestUsesFixedSiteRouteAndRequiresReadGrant() throws {
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-work"])
        let now = Date(timeIntervalSince1970: 1000)
        func tokens(_ scopes: Set<String>) throws -> JiraOAuthTokens {
            try JiraOAuthTokens(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: nil,
                expiresAt: now.addingTimeInterval(10), scopes: scopes)
        }
        let grant = try tokens(["read:jira-work"])
        let request = try JiraAttachmentSettingsRead.make(resource: resource, tokens: grant, now: now)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.url?.absoluteString, resource.apiOrigin.absoluteString + "/rest/api/3/attachment/meta")
        XCTAssertNil(request.httpBody)
        XCTAssertThrowsError(try JiraAttachmentSettingsRead.make(resource: resource, tokens: tokens(["write:jira-work"]), now: now))
        XCTAssertThrowsError(try JiraAttachmentSettingsRead.make(resource: resource, tokens: grant, now: grant.expiresAt))
    }
}
