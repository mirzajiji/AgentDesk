import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// Trusted adapters derive this from the physical project directory; prompts never supply it.
struct ExecutionResource: Codable, Equatable, Sendable {
    let scope: ProjectScope
    let fingerprint: ActionFingerprint
    static func directory(in scope: ProjectScope, device: Int64, inode: UInt64) throws -> Self {
        struct Identity: Encodable { let scope: ProjectScope; let device: Int64; let inode: UInt64 }
        return Self(scope: scope, fingerprint: try .canonical(Identity(scope: scope, device: device, inode: inode)))
    }
}
struct RepositoryEvidence: Sendable {
    let snapshot: RedactedText
    let diff: RedactedText
}
protocol RunRepositoryCapturing: Sendable {
    var context: RedactionContext { get }
    var resource: ExecutionResource { get }
    func captureBaseline() async throws -> RepositoryEvidence
    func captureChanges() async throws -> RepositoryEvidence
}
