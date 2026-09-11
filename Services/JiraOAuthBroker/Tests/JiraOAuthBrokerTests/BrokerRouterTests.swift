import AgentDeskSecurity
import CryptoKit
import Foundation
import XCTest
@testable import JiraOAuthBroker

final class BrokerRouterTests: XCTestCase {
    func testBrowserCallbackNeverReturnsTokensAndNativeClaimIsSingleUse() async throws {
        let attempts = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!)
        let router = try BrokerRouter(attempts: attempts, callbackPath: "/callback") { _ in
            try SecretValue(Data(#"{"access_token":"synthetic-token"}"#.utf8))
        }
        let verifier = String(repeating: "A", count: 43)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let started = try await router.handle(method: "POST", target: "/v1/attempts", body: json(["challenge": challenge]))
        XCTAssertEqual(started.status, 201)
        let payload = try started.withBody { try JSONSerialization.jsonObject(with: $0) as! [String: String] }
        let id = try XCTUnwrap(payload["id"])
        let authorization = try XCTUnwrap(URLComponents(string: XCTUnwrap(payload["authorizationURL"])))
        let state = try XCTUnwrap(authorization.queryItems?.first(where: { $0.name == "state" })?.value)
        let pending = try await router.handle(method: "POST", target: "/v1/attempts/\(id)/claim", body: json(["verifier": verifier]))
        XCTAssertEqual(pending.status, 202)
        let callback = try await router.handle(method: "GET", target: "/callback?state=\(state)&code=synthetic", body: Data())
        XCTAssertEqual(callback.status, 200)
        XCTAssertFalse(callback.withBody { String(decoding: $0, as: UTF8.self).contains("synthetic-token") })
        let claimed = try await router.handle(method: "POST", target: "/v1/attempts/\(id)/claim", body: json(["verifier": verifier]))
        XCTAssertEqual(claimed.status, 200)
        XCTAssertTrue(claimed.withBody { String(decoding: $0, as: UTF8.self).contains("synthetic-token") })
        XCTAssertFalse(String(reflecting: claimed).contains("synthetic-token"))
        let replay = try await router.handle(method: "POST", target: "/v1/attempts/\(id)/claim", body: json(["verifier": verifier]))
        XCTAssertEqual(replay.status, 410)
    }
    func testDeniedConsentIsReportedOnceWithoutExchangingOrEchoingDescription() async throws {
        let attempts = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!)
        let router = try BrokerRouter(attempts: attempts, callbackPath: "/callback") { _ in XCTFail("Denied consent exchanged"); return try SecretValue(Data("unused".utf8)) }
        let verifier = String(repeating: "A", count: 43)
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let attempt = try await attempts.start(challenge: challenge)
        let state = try XCTUnwrap(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value)
        let target = "/callback?state=\(state)&error=access_denied&error_description=synthetic-private"
        let denied = try await router.handle(method: "GET", target: target, body: Data())
        XCTAssertEqual(denied.status, 200)
        XCTAssertFalse(denied.withBody { String(decoding: $0, as: UTF8.self).contains("synthetic-private") })
        let replay = try await router.handle(method: "GET", target: target, body: Data())
        XCTAssertEqual(replay.status, 409)
        let claim = try await router.handle(method: "POST", target: "/v1/attempts/\(attempt.id)/claim", body: json(["verifier": verifier]))
        XCTAssertEqual(claim.status, 403)
        XCTAssertEqual(claim.withBody { String(decoding: $0, as: UTF8.self) }, #"{"error":"denied"}"#)
        let consumed = try await router.handle(method: "POST", target: "/v1/attempts/\(attempt.id)/claim", body: json(["verifier": verifier]))
        XCTAssertEqual(consumed.status, 410)
    }

    func testMalformedTargetsQueriesAndBodiesAreRejected() async throws {
        let attempts = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!)
        let router = try BrokerRouter(attempts: attempts, callbackPath: "/callback") { _ in XCTFail("Malformed request exchanged"); return try SecretValue(Data("unused".utf8)) }
        for target in ["https://other.example/callback", "//other.example/callback", "/callback?state=x&state=y", "/v1/attempts?extra=value", "/callback#fragment"] {
            let response = try await router.handle(method: "GET", target: target, body: Data())
            XCTAssertEqual(response.status, 400)
        }
        let oversized = try await router.handle(method: "POST", target: "/v1/attempts", body: Data(repeating: 65, count: 8193))
        XCTAssertEqual(oversized.status, 400)
    }
    private func json(_ value: [String: String]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
}
