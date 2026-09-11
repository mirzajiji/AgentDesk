import AgentDeskSecurity
import CryptoKit
import Foundation
import Security

/// Native possession proof for a broker attempt, distinct from the browser OAuth state.
struct JiraOAuthClaimProof: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    let challenge: String
    let verifier: SecretValue
    var description: String { "<private OAuth claim proof>" }
    var debugDescription: String { description }
    var customMirror: Mirror { Mirror(self, children: ["proof": description]) }

    init() throws {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, $0.count, $0.baseAddress!) }
        guard status == errSecSuccess else { throw JiraOAuthError.invalidConfiguration }
        try self.init(randomBytes: bytes)
    }
    init(randomBytes: Data) throws {
        guard randomBytes.count == 32 else { throw JiraOAuthError.invalidConfiguration }
        let encoded = Self.base64URL(randomBytes)
        verifier = try SecretValue(Data(encoded.utf8))
        challenge = Self.base64URL(Data(SHA256.hash(data: Data(encoded.utf8))))
    }
    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
