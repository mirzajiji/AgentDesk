import AgentDeskSecurity
import CryptoKit
import Foundation
import Synchronization
import XCTest
@testable import JiraOAuthBroker

@MainActor final class BrokerAttemptRaceTests: XCTestCase {
    func testMaintenanceRemovesUnclaimedTokensWithoutAnotherRequest() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1000))
        let broker = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!, now: { clock.withLock { $0 } })
        let attempt = try await broker.start(challenge: String(repeating: "A", count: 43))
        let state = try XCTUnwrap(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        try await broker.complete(state: state, code: SecretValue(Data("synthetic".utf8))) { _ in
            try SecretValue(Data("synthetic-tokens".utf8))
        }
        let before = await broker.retainedAttemptCount
        XCTAssertEqual(before, 1)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1600) }
        await broker.expirePending()
        let after = await broker.retainedAttemptCount
        XCTAssertEqual(after, 0)
    }

    func testShutdownCancelsExchangeAndPermanentlyClosesAttempts() async throws {
        let broker = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!)
        let attempt = try await broker.start(challenge: String(repeating: "A", count: 43))
        let state = try XCTUnwrap(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value)
        let entered = expectation(description: "Exchange entered")
        let operation = Task {
            try await broker.complete(state: state, code: SecretValue(Data("synthetic".utf8))) { _ in
                entered.fulfill()
                try await Task.sleep(for: .seconds(60))
                return try SecretValue(Data("unexpected".utf8))
            }
        }
        await fulfillment(of: [entered], timeout: 5)
        await broker.shutdown()
        do { try await operation.value; XCTFail("Shutdown accepted exchange") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await broker.retainedAttemptCount
        XCTAssertEqual(count, 0)
        do { _ = try await broker.start(challenge: String(repeating: "A", count: 43)); XCTFail("Closed broker reopened") }
        catch { XCTAssertEqual(error as? BrokerError, .expired) }
    }

    func testExpiryAndBackwardClockInvalidateAttempts() async throws {
        let clock = Mutex(Date(timeIntervalSince1970: 1000))
        let broker = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!, now: { clock.withLock { $0 } })
        let verifier = try SecretValue(Data(String(repeating: "A", count: 43).utf8))
        let challenge = hash(verifier)
        let expired = try await broker.start(challenge: challenge)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1600) }
        do { _ = try await broker.claim(id: expired.id, verifier: verifier); XCTFail("Boundary expiry ignored") }
        catch { XCTAssertEqual(error as? BrokerError, .expired) }
        let backwards = try await broker.start(challenge: challenge)
        clock.withLock { $0 = Date(timeIntervalSince1970: 1599) }
        do { _ = try await broker.claim(id: backwards.id, verifier: verifier); XCTFail("Backward clock accepted") }
        catch { XCTAssertEqual(error as? BrokerError, .expired) }
        clock.withLock { $0 = Date(timeIntervalSince1970: 1600) }
        do { _ = try await broker.claim(id: backwards.id, verifier: verifier); XCTFail("Invalidated attempt revived") }
        catch { XCTAssertEqual(error as? BrokerError, .expired) }
    }

    func testCancellationDuringExchangeRejectsLateResultAndCallbackReplay() async throws {
        let broker = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!)
        let verifier = try SecretValue(Data(String(repeating: "A", count: 43).utf8))
        let attempt = try await broker.start(challenge: hash(verifier))
        let state = try XCTUnwrap(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value)
        let started = expectation(description: "Exchange paused")
        let pause = ExchangePause()
        let code = try SecretValue(Data("synthetic-code".utf8))
        let task = Task {
            try await broker.complete(state: state, code: code) { _ in
                await pause.wait(started)
                return try SecretValue(Data("synthetic-late-tokens".utf8))
            }
        }
        await fulfillment(of: [started], timeout: 2)
        do { try await broker.complete(state: state, code: code) { _ in XCTFail("Callback replay exchanged"); return code }; XCTFail("Replay accepted") }
        catch { XCTAssertEqual(error as? BrokerError, .replay) }
        try await broker.cancel(id: attempt.id, verifier: verifier)
        await pause.resume()
        do { try await task.value; XCTFail("Late exchange recreated cancelled attempt") }
        catch { XCTAssertEqual(error as? BrokerError, .expired) }
        let cancelled = await pause.observedCancellation
        XCTAssertTrue(cancelled, "Cancelling an attempt must cancel its exchange task")
        do { _ = try await broker.claim(id: attempt.id, verifier: verifier); XCTFail("Late tokens claimed") }
        catch { XCTAssertEqual(error as? BrokerError, .expired) }
    }
    private func hash(_ verifier: SecretValue) -> String {
        verifier.withBytes { Data(SHA256.hash(data: $0)).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") }
    }
}
private actor ExchangePause {
    private(set) var observedCancellation = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait(_ started: XCTestExpectation) async {
        await withCheckedContinuation { continuation = $0; started.fulfill() }
        observedCancellation = Task.isCancelled
    }
    func resume() { continuation?.resume(); continuation = nil }
}
