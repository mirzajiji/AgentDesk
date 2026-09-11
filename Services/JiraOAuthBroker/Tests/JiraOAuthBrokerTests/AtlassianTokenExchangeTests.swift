import AgentDeskSecurity
import Foundation
import XCTest
@testable import JiraOAuthBroker

final class AtlassianTokenExchangeTests: XCTestCase {
    func testCodeAndRefreshUseFixedEndpointAndStripExtraResponseFields() async throws {
        let client = try AtlassianTokenExchange(clientID: "synthetic-client", clientSecret: SecretValue(Data("synthetic-secret".utf8)), callback: URL(string: "https://broker.example/callback")!, protocolClasses: [TokenProtocol.self])
        for refresh in [false, true] {
            let input = try SecretValue(Data("synthetic-input".utf8))
            let result = try await (refresh ? client.refresh(token: input) : client.exchange(code: input))
            let object = try result.withBytes { try JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            XCTAssertEqual(object?["access_token"] as? String, "synthetic-access")
            XCTAssertEqual(object?["refresh_token"] as? String, "synthetic-rotated")
            XCTAssertNil(object?["upstream_private"])
            XCTAssertFalse(String(reflecting: result).contains("synthetic-access"))
        }
        await client.close()
    }
    func testRedirectErrorAndMalformedSuccessReturnSafeFailure() async throws {
        let client = try AtlassianTokenExchange(clientID: "synthetic-client", clientSecret: SecretValue(Data("synthetic-secret".utf8)), callback: URL(string: "https://broker.example/callback")!, protocolClasses: [TokenProtocol.self])
        for code in ["redirect", "failure", "malformed", "oversized"] {
            do { _ = try await client.exchange(code: SecretValue(Data(code.utf8))); XCTFail("Invalid exchange accepted") }
            catch { XCTAssertEqual(error as? BrokerError, .exchangeFailed); XCTAssertFalse(String(reflecting: error).contains("upstream-private")) }
        }
        await client.close()
    }
}
private final class TokenProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: String] ?? [:]
        let refresh = body["grant_type"] == "refresh_token"
        let mode = body[refresh ? "refresh_token" : "code"] ?? "failure"
        let valid = request.url?.absoluteString == "https://auth.atlassian.com/oauth/token" && request.httpMethod == "POST"
            && body["client_id"] == "synthetic-client" && body["client_secret"] == "synthetic-secret"
            && (refresh ? body["redirect_uri"] == nil : body["redirect_uri"] == "https://broker.example/callback")
        let status = !valid || mode == "failure" ? 400 : mode == "redirect" ? 302 : 200
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let payload = mode == "malformed" ? #"{"access_token":"","expires_in":0,"scope":""}"# : #"{"access_token":"synthetic-access","refresh_token":"synthetic-rotated","expires_in":3600,"scope":"read:jira-user read:jira-work offline_access","token_type":"Bearer","upstream_private":"upstream-private"}"#
        client?.urlProtocol(self, didLoad: mode == "oversized" ? Data(repeating: 65, count: 65_537) : Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
