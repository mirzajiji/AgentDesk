import AgentDeskCore
import AgentDeskSecurity
import Foundation

public enum EvidenceStoreError: Error, Equatable, Sendable {
    case unregisteredRun, conflictingBinding, conflictingRecord, invalidInput, limitExceeded
    case missingArtifact, corruptArtifact, unsafeFile, invalidLocation
    case fileSystem(Int32)
}
public enum EvidenceSource: String, Codable, Sendable { case runtime, providerCommand, providerResponse, repository, user }
public enum EvidenceBasis: String, Codable, Sendable { case observed, interpretation }
public enum EvidenceFormat: String, Codable, Sendable { case text, markdown, json, diff }
public enum EvidenceKind: String, Codable, Sendable { case trace, output, command, repositorySnapshot, changedFiles, diff }

/// Sanitized operational content returned by storage. Writing still requires a fresh RedactedText.
public struct StoredEvidenceContent: Codable, Equatable, Sendable {
    public let text: String
    public let classification: EvidenceClassification
    public let redactionCount: Int
    public let policyVersion: Int
    init(_ value: RedactedText) {
        text = value.text; classification = value.classification
        redactionCount = value.redactionCount; policyVersion = value.policyVersion
    }
    init(text: String, classification: EvidenceClassification, redactionCount: Int, policyVersion: Int) {
        self.text = text; self.classification = classification
        self.redactionCount = redactionCount; self.policyVersion = policyVersion
    }
    func validate(maximumBytes: Int) throws {
        guard text.utf8.count <= maximumBytes, !text.utf8.contains(0), classification != .secret,
              policyVersion == 1, redactionCount >= 0, redactionCount <= 262_144,
              redactionCount == 0 || classification == .confidential else { throw EvidenceStoreError.invalidInput }
    }
}

/// Frozen before execution. Older runs without this record retain their original history.
public struct EvidenceRunBinding: Codable, Equatable, Sendable {
    public let context: RedactionContext
    public let agentID: AgentID
    public let agentRevision: Int
    public let configurationFingerprint: ActionFingerprint
    public let snapshot: StoredEvidenceContent
    func validate() throws {
        guard (1...1_000_000).contains(agentRevision) else { throw EvidenceStoreError.invalidInput }
        try snapshot.validate(maximumBytes: 65_536)
    }
}

/// Names and filesystem paths are generated from IDs; untrusted labels belong in sanitized content.
public struct EvidenceRecord: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let context: RedactionContext
    public let agentID: AgentID
    public let sequence: Int64
    public let kind: EvidenceKind
    public let source: EvidenceSource
    public let basis: EvidenceBasis
    public let format: EvidenceFormat
    public let classification: EvidenceClassification
    public let redactionCount: Int
    public let policyVersion: Int
    public let fingerprint: ActionFingerprint
    public let byteCount: Int
    public let recordedAt: Date
    func validate() throws {
        guard (1...4_096).contains(sequence), (0...1_048_576).contains(byteCount),
              kind != .trace || byteCount <= 65_536,
              classification != .secret, policyVersion == 1,
              (0...262_144).contains(redactionCount), redactionCount == 0 || classification == .confidential,
              recordedAt.timeIntervalSince1970.isFinite, recordedAt.timeIntervalSince1970 >= 0,
              source != .providerResponse || basis == .interpretation else { throw EvidenceStoreError.invalidInput }
    }
}
public struct StoredTrace: Equatable, Sendable { public let record: EvidenceRecord; public let content: StoredEvidenceContent }
public struct ArtifactRecoveryIssue: Equatable, Sendable {
    public enum Reason: String, Sendable { case missing, corrupt, unsafe }
    public let id: UUID
    public let reason: Reason
}
public struct EvidenceRecoveryReport: Equatable, Sendable {
    public let unavailable: [ArtifactRecoveryIssue]
    public let orphanIDs: [UUID]
    public let stagedFileCount: Int
    public let unexpectedFileCount: Int
}
