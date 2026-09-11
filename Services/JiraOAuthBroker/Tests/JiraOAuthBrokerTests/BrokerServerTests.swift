import AgentDeskSecurity
import Foundation
import XCTest
@testable import JiraOAuthBroker

final class BrokerServerTests: XCTestCase {
    @MainActor func testConnectionDeadlineCancelsActiveExchange() async throws {
        let entered = expectation(description: "Exchange started")
        let cancelled = expectation(description: "Exchange cancelled")
        let attempts = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!)
        let attempt = try await attempts.start(challenge: String(repeating: "A", count: 43))
        let state = try XCTUnwrap(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        let router = try BrokerRouter(attempts: attempts, callbackPath: "/callback") { _ in
            entered.fulfill()
            do { try await Task.sleep(for: .seconds(60)) }
            catch { cancelled.fulfill(); throw error }
            return try SecretValue(Data("unexpected".utf8))
        }
        let server = BrokerServer(router: router, connectionTimeout: .seconds(1))
        let port = try await server.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let request = Task {
            try await session.data(from: URL(string: "http://127.0.0.1:\(port)/callback?state=\(state)&code=synthetic")!)
        }
        await fulfillment(of: [entered, cancelled], timeout: 5)
        request.cancel()
        _ = try? await request.value
        await server.stop()
    }

    func testExhaustedAdmissionBudgetReturns429() async throws {
        let attempts = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!)
        let router = try BrokerRouter(attempts: attempts, callbackPath: "/callback") { _ in try SecretValue(Data("unused".utf8)) }
        var budget = BrokerRequestBudget(capacity: 1, refillPerSecond: 0.0001)
        XCTAssertTrue(budget.admit())
        let server = BrokerServer(router: router, connectionTimeout: .seconds(5), requestBudget: budget)
        let port = try await server.start()
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        do {
            let (_, response) = try await session.data(from: URL(string: "http://127.0.0.1:\(port)/callback")!)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 429)
        } catch {
            await server.stop()
            throw error
        }
        await server.stop()
    }

    func testLoopbackRequestSecurityHeadersAndRestart() async throws {
        let attempts = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!)
        let router = try BrokerRouter(attempts: attempts, callbackPath: "/callback") { _ in try SecretValue(Data("unused".utf8)) }
        let server = BrokerServer(router: router)
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        for _ in 0..<2 {
            let port = try await server.start()
            XCTAssertNotEqual(port, 0)
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/v1/attempts")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["challenge": String(repeating: "A", count: 43)])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let (data, response) = try await session.data(for: request)
            let http = try XCTUnwrap(response as? HTTPURLResponse)
            XCTAssertEqual(http.statusCode, 201)
            XCTAssertEqual(http.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertEqual(http.value(forHTTPHeaderField: "Referrer-Policy"), "no-referrer")
            let payload = try JSONSerialization.jsonObject(with: data) as? [String: String]
            XCTAssertNotNil(payload?["id"])
            XCTAssertTrue(payload?["authorizationURL"]?.hasPrefix("https://auth.atlassian.com/authorize?") == true)
            await server.stop()
        }
    }
}
