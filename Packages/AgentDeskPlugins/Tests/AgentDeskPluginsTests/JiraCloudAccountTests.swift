import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraCloudAccountTests: XCTestCase {
    func testValidIdentityRequiresActiveAccountAndRequiredFields() throws {
        func response(_ body: String) -> JiraHTTPResponse { .init(status: 200, body: Data(body.utf8)) }
        let account = try JiraCloudAccount.decode(response(#"{"accountId":"synthetic-id","displayName":"Synthetic User","active":true}"#))
        XCTAssertEqual(account.accountID, "synthetic-id")
        XCTAssertEqual(account.displayName, "Synthetic User")
        for body in [#"{"accountId":"id","displayName":"User","active":false}"#,
                     #"{"accountId":"","displayName":"User","active":true}"#,
                     #"{"displayName":"Anonymous","active":true}"#, "not json"] {
            XCTAssertThrowsError(try JiraCloudAccount.decode(response(body)))
        }
    }
    func testFailureResponsesExposeCategoriesWithoutServerBody() throws {
        let cases: [(Int, JiraServiceError)] = [(401, .authenticationRequired), (403, .accessDenied),
            (404, .notFound), (429, .rateLimited), (503, .unavailable), (302, .invalidResponse)]
        for (status, expected) in cases {
            XCTAssertThrowsError(try JiraCloudAccount.decode(.init(status: status, body: Data("private server detail".utf8)))) { error in
                XCTAssertEqual(error as? JiraServiceError, expected)
                XCTAssertFalse(String(describing: error).contains("private server detail"))
            }
        }
    }
}
