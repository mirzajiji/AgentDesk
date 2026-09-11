import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraOAuthBrokerClientTests: XCTestCase {
    func testStartValidatesRegistrationAndClaimReturnsSecretTokens() async throws {
        let client = try JiraOAuthBrokerClient(origin: URL(string: "https://broker.example")!, clientID: "synthetic-client",
            callback: URL(string: "https://broker.example/callback")!, protocolClasses: [NativeBrokerProtocol.self])
        let proof = try JiraOAuthClaimProof()
        let attempt = try await client.start(proof: proof)
        XCTAssertEqual(attempt.authorizationURL.host, "auth.atlassian.com")
        let tokens = try await client.claim(attempt, proof: proof, now: Date(timeIntervalSince1970: 1000))
        XCTAssertEqual(tokens?.expiresAt, Date(timeIntervalSince1970: 4600))
        XCTAssertFalse(String(reflecting: tokens?.accessToken).contains("synthetic-access"))
        try await client.cancel(attempt, proof: proof)
        await client.close()
    }
    func testWriteConsentMustMatchExplicitNativeAccessChoice() async throws {
        for access in JiraOAuthAccess.allCases {
            let client = try JiraOAuthBrokerClient(origin: URL(string: "https://write.example")!, clientID: "synthetic-client",
                callback: URL(string: "https://broker.example/callback")!, access: access, protocolClasses: [NativeBrokerProtocol.self])
            do {
                _ = try await client.start(proof: JiraOAuthClaimProof())
                XCTAssertEqual(access, .readWrite)
            } catch {
                XCTAssertEqual(access, .readOnly)
                XCTAssertEqual(error as? JiraServiceError, .invalidResponse)
            }
            await client.close()
        }
    }
    func testForeignAuthorizationDestinationAndWrongClientAreRejected() async throws {
        for (host, clientID) in [("evil.example", "synthetic-client"), ("broker.example", "wrong-client")] {
            let client = try JiraOAuthBrokerClient(origin: URL(string: "https://" + host)!, clientID: clientID,
                callback: URL(string: "https://broker.example/callback")!, protocolClasses: [NativeBrokerProtocol.self])
            do { _ = try await client.start(proof: JiraOAuthClaimProof()); XCTFail("Untrusted authorization accepted") }
            catch { XCTAssertEqual(error as? JiraServiceError, .invalidResponse) }
            await client.close()
        }
    }
}
final class NativeBrokerProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let start = url.path == "/v1/attempts", cancel = url.path.hasSuffix("/cancel")
        var authorization = URLComponents(string: url.host == "evil.example" ? "https://phishing.example/authorize" : "https://auth.atlassian.com/authorize")!
        authorization.queryItems = [.init(name: "client_id", value: "synthetic-client"), .init(name: "redirect_uri", value: "https://broker.example/callback"),
            .init(name: "audience", value: "api.atlassian.com"), .init(name: "response_type", value: "code"), .init(name: "prompt", value: "consent"),
            .init(name: "scope", value: url.host == "write.example" ? "read:jira-user read:jira-work write:jira-work offline_access" : "read:jira-user read:jira-work offline_access"), .init(name: "state", value: String(repeating: "A", count: 43))]
        let body = start ? try! JSONSerialization.data(withJSONObject: ["id": UUID().uuidString, "authorizationURL": authorization.url!.absoluteString])
            : Data(#"{"access_token":"synthetic-access","refresh_token":"synthetic-refresh","expires_in":3600,"scope":"read:jira-user read:jira-work offline_access"}"#.utf8)
        let response = HTTPURLResponse(url: url, statusCode: url.host == "refresh-failed.example" && url.path == "/v1/refresh" ? 502 : start ? 201 : cancel ? 204 : 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !cancel { client?.urlProtocol(self, didLoad: body) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
