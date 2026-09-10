import AgentDeskCore
import AgentDeskPersistence
import Foundation

/// Artifact bytes and provenance verified by the authorized native read boundary. Interpretation
/// remains interpretation; successful verification does not establish a defect or change its status.
public struct VerifiedBugEvidence: Sendable {
    public let reference: BugEvidenceReference
    public let record: EvidenceRecord
    public let content: StoredEvidenceContent
    init(reference: BugEvidenceReference, record: EvidenceRecord, content: StoredEvidenceContent) throws {
        guard record.id == reference.artifact, record.context.scope == reference.scope,
              record.context.environmentID == reference.environment, record.context.runID == reference.run,
              record.agentID == reference.agent, record.fingerprint == reference.sanitizedFingerprint,
              try ActionFingerprint(bytes: Data(content.text.utf8)) == reference.sanitizedFingerprint else {
            throw BugRegistryError.unavailableReference
        }
        self.reference = reference; self.record = record; self.content = content
    }
}
