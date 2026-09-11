import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

struct PreparedBugContext: Sendable {
    let content: RedactedText
    let validate: @Sendable () async throws -> Void
}

public struct BugReviewMatch: Codable, Equatable, Sendable {
    public let existingID: BugID
    public let result: BugComparisonResult
}

/// A read-only, sanitized review. Construction is restricted to the authorized native service.
/// This does not authorize external publication or a registry update.
public struct PreparedBugReview: Sendable {
    public let incomingID: BugID
    public let scope: ProjectScope
    public let environment: EnvironmentID
    public let matches: [BugReviewMatch]
    public let readiness: BugComparisonResult.Classification?
    public let content: RedactedText
    public let expiresAt: Date
    /// Exposes only the current decision classification; raw historical reason text stays private.
    public func recordedResolution(for existingID: BugID) -> BugReviewDecision.Resolution? {
        decisions.first { $0.existingID == existingID }?.resolution
    }
    public var registeredCandidateIDs: Set<BugID> {
        Set(snapshot.records.filter { $0.record.id != incomingID && $0.record.content.ticket != nil }.map { $0.record.id })
    }
    let owner: UUID
    let snapshot: BugComparisonSnapshot
    let store: ProjectBugStore
    let decisions: [BugReviewDecision]
    let validate: @Sendable () async throws -> Void
}

struct BugReviewService {
    static func prepare(store: ProjectBugStore, incomingID: BugID, environment: EnvironmentID,
                        owner: UUID, redactor: ContentRedactor,
                        authorize: @escaping @Sendable () async throws -> Void,
                        verify: @escaping @Sendable (BugEvidenceReference) async throws -> VerifiedBugEvidence) async throws -> PreparedBugReview {
        try await authorize()
        let snapshot = try await store.comparisonSnapshot(in: store.scope, environment: environment)
        guard let incoming = snapshot.records.first(where: { $0.record.id == incomingID }) else { throw BugRegistryError.unavailableReference }
        let decisions = try await store.comparisonDecisions(for: incomingID, snapshot: snapshot, in: store.scope)
        let matches = try snapshot.records.filter { $0.record.id != incomingID }.map {
            BugReviewMatch(existingID: $0.record.id, result: try BugComparison.compare(incoming, with: $0))
        }
        let selectedIDs = Set(matches.filter { [.duplicate, .possibleDuplicate, .related].contains($0.result.classification) }.map(\.existingID))
        let selected = [incoming] + snapshot.records.filter { selectedIDs.contains($0.record.id) }
        guard selected.count <= 32 else { throw BugRegistryError.limitExceeded }
        var sources: [Source] = [], references: [BugEvidenceReference] = []
        for input in selected {
            try await authorize()
            var evidence: [Artifact] = []
            for reference in input.record.content.evidence {
                guard references.count < 128 else { throw BugRegistryError.limitExceeded }
                let checked = try await verify(reference)
                references.append(reference)
                evidence.append(.init(reference: reference, source: checked.record.source, basis: checked.record.basis, text: checked.content.text))
            }
            sources.append(Source(id: input.record.id, revision: input.record.revision, content: input.record.content,
                requirements: input.activeRequirements.map { .init(id: $0.id, version: $0.version, content: $0.content) },
                staleRequirements: input.staleRequirements, evidence: evidence))
        }
        let packet = Packet(scope: store.scope, environment: environment, incomingID: incomingID,
            comparedRecords: matches.count, readiness: BugComparison.readiness(incoming), matches: matches, sources: sources)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let raw = try encoder.encode(packet)
        guard raw.count <= 32_768 else { throw BugRegistryError.limitExceeded }
        let safe = try redactor.redactJSON(String(decoding: raw, as: UTF8.self), in: redactor.context)
        guard safe.text.utf8.count <= 32_768 else { throw BugRegistryError.limitExceeded }
        let expires = Date().addingTimeInterval(300), retainedReferences = references
        let validation: @Sendable () async throws -> Void = {
            try Task.checkCancellation()
            guard Date() < expires else { throw BugRegistryError.invalidReview }
            try await authorize()
            try await store.validate(snapshot, in: snapshot.scope)
            for reference in retainedReferences { _ = try await verify(reference) }
            try await authorize()
        }
        try await validation()
        return PreparedBugReview(incomingID: incomingID, scope: store.scope, environment: environment,
            matches: matches, readiness: BugComparison.readiness(incoming), content: safe, expiresAt: expires, owner: owner,
            snapshot: snapshot, store: store, decisions: decisions, validate: validation)
    }
    private struct Packet: Encodable {
        let schemaVersion = 1
        let scope: ProjectScope; let environment: EnvironmentID; let incomingID: BugID
        let comparedRecords: Int; let readiness: BugComparisonResult.Classification?; let matches: [BugReviewMatch]; let sources: [Source]
    }
    private struct Source: Encodable {
        let id: BugID; let revision: Int; let content: BugDraft
        let requirements: [Requirement]; let staleRequirements: Bool; let evidence: [Artifact]
    }
    private struct Requirement: Encodable { let id: RequirementID; let version: Int; let content: RequirementDraft }
    private struct Artifact: Encodable {
        let reference: BugEvidenceReference; let source: EvidenceSource; let basis: EvidenceBasis; let text: String
    }
}
