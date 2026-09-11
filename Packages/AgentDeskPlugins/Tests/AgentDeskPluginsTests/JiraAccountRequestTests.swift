import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraAccountRequestTests: XCTestCase {
    func testRequestUsesExactGatewayAndOnlyAccessToken() throws {
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-user"])
        let request = try JiraAccountRequest.make(resource: resource, tokens: tokens(), now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(request.url?.absoluteString, resource.apiOrigin.absoluteString + "/rest/api/3/myself")
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-access")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.httpBody)
        XCTAssertFalse(String(describing: request.allHTTPHeaderFields).contains("synthetic-refresh"))
    }

    func testExpiryAndBothGrantScopesAreRequired() throws {
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-user"])
        for now in [Date(timeIntervalSince1970: 2000), Date(timeIntervalSince1970: 2001), Date(timeIntervalSince1970: .infinity)] {
            XCTAssertThrowsError(try JiraAccountRequest.make(resource: resource, tokens: tokens(), now: now)) {
                XCTAssertEqual($0 as? JiraServiceError, .authenticationRequired)
            }
        }
        XCTAssertThrowsError(try JiraAccountRequest.make(resource: resource, tokens: tokens(scopes: ["read:jira-work"]), now: Date(timeIntervalSince1970: 1000)))
        XCTAssertThrowsError(try JiraAccountRequest.make(resource: .init(id: UUID(), scopes: []), tokens: tokens(), now: Date(timeIntervalSince1970: 1000)))
    }

    func testAuthenticatedProfileLoadsThroughIsolatedTransport() async throws {
        let resource = JiraCloudResource(id: UUID(), scopes: ["read:jira-user"])
        let transport = try JiraHTTPTransport(origin: resource.apiOrigin, protocolClasses: [AccountProtocol.self])
        let account = try await JiraAccountRequest.load(resource: resource, tokens: tokens(),
            now: Date(timeIntervalSince1970: 1000), transport: transport)
        XCTAssertEqual(account.accountID, "synthetic-account")
        XCTAssertEqual(account.displayName, "Synthetic User")
        await transport.close()
    }

    private func tokens(scopes: Set<String> = ["read:jira-user"]) throws -> JiraOAuthTokens {
        try .init(accessToken: SecretValue(Data("synthetic-access".utf8)), refreshToken: SecretValue(Data("synthetic-refresh".utf8)),
                  expiresAt: Date(timeIntervalSince1970: 2000), scopes: scopes)
    }
}

private final class AccountProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let valid = request.httpMethod == "GET"
            && request.url?.host == "api.atlassian.com"
            && request.url?.path.hasSuffix("/rest/api/3/myself") == true
            && request.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-access"
        let response = HTTPURLResponse(url: request.url!, statusCode: valid ? 200 : 401, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"accountId":"synthetic-account","displayName":"Synthetic User","active":true}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
