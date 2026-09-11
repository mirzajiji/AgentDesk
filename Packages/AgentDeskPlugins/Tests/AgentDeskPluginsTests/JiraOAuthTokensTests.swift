import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraOAuthTokensTests: XCTestCase {
    func testValidTokensAreSecretValuesAndExpiryIsExact() throws {
        let body = Data(#"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600,"scope":"read:jira-user offline_access","token_type":"Bearer"}"#.utf8)
        let tokens = try JiraOAuthTokens.decode(.init(status: 200, body: body), now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(tokens.expiresAt, Date(timeIntervalSince1970: 4600))
        XCTAssertEqual(tokens.scopes, ["read:jira-user", "offline_access"])
        XCTAssertFalse(String(describing: tokens.accessToken).contains("synthetic-access"))
        XCTAssertFalse(String(describing: tokens.refreshToken).contains("synthetic-refresh"))
    }
    func testMalformedAndExpiredTokenResponsesAreRejected() throws {
        for fields: [String: Any] in [
            ["access_token": "", "expires_in": 3600, "scope": "read:jira-user"],
            ["access_token": "header\r\ninjection", "expires_in": 3600, "scope": "read:jira-user"],
            ["access_token": "token", "expires_in": 0, "scope": "read:jira-user"],
            ["access_token": "token", "expires_in": 3600, "scope": "read:jira-user", "refresh_token": ""],
            ["access_token": "token", "expires_in": 3600, "scope": "read:jira-user", "token_type": "Basic"]
        ] {
            XCTAssertThrowsError(try JiraOAuthTokens.decode(.init(status: 200,
                body: JSONSerialization.data(withJSONObject: fields)), now: Date()))
        }
    }
}
