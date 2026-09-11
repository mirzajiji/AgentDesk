#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskRuntime
import AgentDeskSecurity
import Foundation

/// Decodes only the already-redacted, service-produced packet for native presentation.
struct NativeBugReviewEvidence {
    struct Requirement: Decodable, Identifiable {
        let id: RequirementID
        let version: Int
        let content: RequirementDraft
    }
    struct Artifact: Decodable {
        let reference: BugEvidenceReference
        let source: EvidenceSource
        let basis: EvidenceBasis
        let text: String
    }
    struct Source: Decodable, Identifiable {
        let id: BugID
        let revision: Int
        let content: BugDraft
        let requirements: [Requirement]
        let staleRequirements: Bool
        let evidence: [Artifact]
    }
    private struct Packet: Decodable {
        let schemaVersion: Int
        let scope: ProjectScope
        let environment: EnvironmentID
        let incomingID: BugID
        let sources: [Source]
    }
    let sources: [Source]
    init(_ review: PreparedBugReview) throws {
        let packet = try ConfigurationJSON.decode(Packet.self, from: Data(review.content.text.utf8))
        guard packet.schemaVersion == 1, packet.scope == review.scope, packet.environment == review.environment,
              packet.incomingID == review.incomingID, packet.sources.contains(where: { $0.id == review.incomingID }),
              Set(packet.sources.map(\.id)).count == packet.sources.count else { throw BugRegistryError.invalidDocument }
        for source in packet.sources {
            try source.content.validate(in: review.scope, id: source.id)
            guard source.content.environment == review.environment,
                  source.evidence.allSatisfy({ $0.reference.scope == review.scope && $0.reference.environment == review.environment }) else {
                throw BugRegistryError.scopeMismatch
            }
        }
        sources = packet.sources
    }
}
#endif
