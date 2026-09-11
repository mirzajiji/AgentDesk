import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraOAuthRefreshClientTests: XCTestCase {
    func testRefreshRequiresRotatedTokenAndUsesFixedRequest() async throws {
        for host in ["valid.example", "missing.example", "failed.example"] {
            let client = try JiraOAuthBrokerClient(origin: URL(string: "https://" + host)!, clientID: "synthetic",
                callback: URL(string: "https://broker.example/callback")!, protocolClasses: [RefreshClientProtocol.self])
            do {
                let tokens = try await client.refresh(SecretValue(Data("synthetic-old".utf8)), now: Date(timeIntervalSince1970: 1000))
                XCTAssertEqual(host, "valid.example")
                XCTAssertEqual(tokens.refreshToken?.withBytes { String(decoding: $0, as: UTF8.self) }, "synthetic-new")
                XCTAssertEqual(tokens.expiresAt, Date(timeIntervalSince1970: 4600))
            } catch { XCTAssertNotEqual(host, "valid.example") }
            await client.close()
        }
    }
}
private final class RefreshClientProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.path, "/v1/refresh")
        XCTAssertNil(request.url?.query)
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
        XCTAssertEqual(try? JSONSerialization.jsonObject(with: data) as? [String: String], ["refresh_token": "synthetic-old"])
        let url = request.url!
        let body = url.host == "missing.example"
            ? #"{"access_token":"synthetic-access","expires_in":3600,"scope":"read:jira-work"}"#
            : #"{"access_token":"synthetic-access","refresh_token":"synthetic-new","expires_in":3600,"scope":"read:jira-work"}"#
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: url.host == "failed.example" ? 502 : 200, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
