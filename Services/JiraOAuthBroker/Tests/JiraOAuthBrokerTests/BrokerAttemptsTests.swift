import AgentDeskSecurity
import CryptoKit
import Foundation
import XCTest
@testable import JiraOAuthBroker

final class BrokerAttemptsTests: XCTestCase {
    func testClaimRequiresProofAndCanOnlyConsumeOnce() async throws {
        let broker = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!)
        let value = String(repeating: "A", count: 43)
        let verifier = try SecretValue(Data(value.utf8))
        let challenge = Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let attempt = try await broker.start(challenge: challenge)
        let state = try XCTUnwrap(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value)
        do { _ = try await broker.claim(id: attempt.id, verifier: verifier); XCTFail("Pending claim succeeded") }
        catch { XCTAssertEqual(error as? BrokerError, .pending) }
        let tokens = try SecretValue(Data("synthetic-token-bundle".utf8))
        try await broker.complete(state: state, code: SecretValue(Data("synthetic-code".utf8))) { _ in tokens }
        do { _ = try await broker.claim(id: attempt.id, verifier: SecretValue(Data(String(repeating: "B", count: 43).utf8))); XCTFail("Wrong proof accepted") }
        catch { XCTAssertEqual(error as? BrokerError, .invalidProof) }
        let result = try await broker.claim(id: attempt.id, verifier: verifier)
        XCTAssertEqual(result.withBytes { $0 }, tokens.withBytes { $0 })
        do { _ = try await broker.claim(id: attempt.id, verifier: verifier); XCTFail("Claim replayed") }
        catch { XCTAssertEqual(error as? BrokerError, .expired) }
    }
    func testCapacityAndCancelledAttemptRejectCallback() async throws {
        let broker = try BrokerAttempts(clientID: "synthetic", callback: URL(string: "https://broker.example/callback")!, capacity: 1)
        let value = String(repeating: "A", count: 43)
        let challenge = Data(SHA256.hash(data: Data(value.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let attempt = try await broker.start(challenge: challenge)
        do { _ = try await broker.start(challenge: challenge); XCTFail("Capacity ignored") }
        catch { XCTAssertEqual(error as? BrokerError, .capacity) }
        try await broker.cancel(id: attempt.id, verifier: SecretValue(Data(value.utf8)))
        let state = try XCTUnwrap(URLComponents(url: attempt.authorizationURL, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "state" })?.value)
        do { try await broker.complete(state: state, code: SecretValue(Data("code".utf8))) { _ in XCTFail("Cancelled callback exchanged"); return try SecretValue(Data("tokens".utf8)) }; XCTFail("Cancelled attempt completed") }
        catch { XCTAssertEqual(error as? BrokerError, .expired) }
    }
}
