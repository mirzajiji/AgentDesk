import CryptoKit
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraOAuthClaimProofTests: XCTestCase {
    func testChallengeHashesEncodedVerifierAndDescriptionsStayPrivate() throws {
        let proof = try JiraOAuthClaimProof(randomBytes: Data(0..<32))
        let verifier = proof.verifier.withBytes { $0 }
        XCTAssertEqual(verifier.count, 43)
        let digest = Data(SHA256.hash(data: verifier)).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(proof.challenge, digest)
        XCTAssertFalse(String(reflecting: proof).contains(String(decoding: verifier, as: UTF8.self)))
        XCTAssertThrowsError(try JiraOAuthClaimProof(randomBytes: Data(count: 31)))
        XCTAssertNotEqual(try JiraOAuthClaimProof().challenge, try JiraOAuthClaimProof().challenge)
    }
}
