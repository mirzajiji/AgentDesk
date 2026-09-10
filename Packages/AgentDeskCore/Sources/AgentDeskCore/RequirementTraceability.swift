import Foundation

public struct TraceabilitySubject: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case automatedTest, manualTest, bug, documentation, workflow }
    public let kind: Kind
    public let id: RequirementID
    public init(kind: Kind, id: RequirementID) { self.kind = kind; self.id = id }
}

public struct RequirementLinkRequest: Equatable, Sendable {
    public let id: RequirementID
    public let historicalVersion: Int?
    public init(id: RequirementID, historicalVersion: Int? = nil) {
        self.id = id; self.historicalVersion = historicalVersion
    }
}

public struct TracedRequirement: Codable, Equatable, Sendable {
    public let id: RequirementID
    public let version: Int
    public let fingerprint: ActionFingerprint
    public let historical: Bool
}

/// Project memory metadata. Referenced subjects are inert identities, not executable operations or URLs.
public struct RequirementTraceRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let scope: ProjectScope
    public let subject: TraceabilitySubject
    public let title: String
    public let environment: EnvironmentID
    public let revision: Int
    public let requirements: [TracedRequirement]
    public let archived: Bool
    public let changeReason: String
    public let updatedAt: Date
    func validate() throws {
        guard schemaVersion == 1, (1...1_000_000).contains(revision), (1...64).contains(requirements.count),
              Set(requirements.map(\.id)).count == requirements.count,
              updatedAt.timeIntervalSince1970.isFinite, updatedAt.timeIntervalSince1970 >= 0 else { throw RequirementError.invalidDocument }
        try RequirementDraft.checkText(title, maximum: 1_024)
        try RequirementDraft.checkText(changeReason, maximum: 4_096)
        guard requirements.allSatisfy({ (1...1_000_000).contains($0.version) }) else { throw RequirementError.invalidDocument }
    }
}

public struct TraceabilityProposal: Equatable, Sendable {
    public let token: UUID
    public let candidate: RequirementTraceRecord
    public let expiresAt: Date
    let previousFingerprint: ActionFingerprint?
}

public struct RequirementImpact: Equatable, Sendable {
    public enum Status: String, Sendable { case current, potentiallyStale, unavailable }
    public let record: RequirementTraceRecord
    public let linked: TracedRequirement
    public let activeVersion: Int?
    public let status: Status
}

public struct RequirementImpactReport: Equatable, Sendable {
    public let scope: ProjectScope
    public let requirement: RequirementID
    public let links: [RequirementImpact]
    public var affectedCounts: [TraceabilitySubject.Kind: Int] {
        Dictionary(grouping: links.filter { $0.status != .current }, by: { $0.record.subject.kind }).mapValues(\.count)
    }
}

public struct BugRequirementImpact: Equatable, Sendable {
    public let record: BugRecord
    public let linked: BugRequirementReference
    public let activeVersion: Int?
    public let status: RequirementImpact.Status
}
public struct BugRequirementImpactReport: Equatable, Sendable {
    public let scope: ProjectScope
    public let requirement: RequirementID
    public let links: [BugRequirementImpact]
}
