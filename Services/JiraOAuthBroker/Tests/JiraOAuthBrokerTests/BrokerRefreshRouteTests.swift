import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import JiraOAuthBroker

final class BrokerRefreshRouteTests: XCTestCase {
    func testFixedRefreshRouteRejectsOverridesAndDoesNotRetryFailure() async throws {
        let attempts = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!)
        let calls = Mutex(0)
        let router = try BrokerRouter(attempts: attempts, callbackPath: "/callback", refresh: { token in
            calls.withLock { $0 += 1 }
            XCTAssertEqual(token.withBytes { String(decoding: $0, as: UTF8.self) }, "synthetic-refresh")
            throw BrokerError.exchangeFailed
        }, exchange: { _ in XCTFail("Wrong exchange"); return try SecretValue(Data("unused".utf8)) })
        for payload in [["refresh_token": "synthetic-refresh", "client_id": "foreign"],
                        ["refresh_token": "synthetic-refresh", "destination": "https://foreign.example"],
                        ["refresh_token": ""], ["refresh_token": "bad\r\nvalue"]] {
            let result = try await router.handle(method: "POST", target: "/v1/refresh", body: JSONSerialization.data(withJSONObject: payload))
            XCTAssertEqual(result.status, 400)
        }
        XCTAssertEqual(calls.withLock { $0 }, 0)
        let failed = try await router.handle(method: "POST", target: "/v1/refresh", body: Data(#"{"refresh_token":"synthetic-refresh"}"#.utf8))
        XCTAssertEqual(failed.status, 502)
        XCTAssertEqual(calls.withLock { $0 }, 1)
        XCTAssertFalse(failed.withBody { String(decoding: $0, as: UTF8.self).contains("synthetic-refresh") })
    }
    func testRefreshReturnsOnlyExplicitSecretBody() async throws {
        let attempts = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!)
        let router = try BrokerRouter(attempts: attempts, callbackPath: "/callback", refresh: { _ in
            try SecretValue(Data(#"{"access_token":"synthetic-new"}"#.utf8))
        }, exchange: { _ in throw BrokerError.invalidRequest })
        let result = try await router.handle(method: "POST", target: "/v1/refresh", body: Data(#"{"refresh_token":"synthetic-refresh"}"#.utf8))
        XCTAssertEqual(result.status, 200)
        XCTAssertFalse(String(reflecting: result).contains("synthetic-new"))
        XCTAssertTrue(result.withBody { String(decoding: $0, as: UTF8.self).contains("synthetic-new") })
    }
}
