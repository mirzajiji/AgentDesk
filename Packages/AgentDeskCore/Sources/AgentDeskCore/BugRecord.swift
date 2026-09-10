import Foundation

public enum BugEntity: Sendable {}
public typealias BugID = EntityID<BugEntity>
public enum BugRegistryError: Error, Equatable, Sendable {
    case invalidDocument, scopeMismatch, staleRevision, invalidReview, limitExceeded, unavailableReference
}
public enum BugStatus: String, Codable, CaseIterable, Sendable { case open, resolved, closed, archived }
public enum BugOrigin: String, Codable, CaseIterable, Sendable { case manual, agent, imported, playwright, api, database }
public enum BugAssessment: String, Codable, CaseIterable, Sendable { case reported, observed, blocked }

/// A manually supplied association. Storing it does not contact Jira or prove the remote ticket exists.
public struct ExternalBugTicket: Codable, Equatable, Sendable {
    public let key: String?
    public let url: String?
    public init(key: String? = nil, url: String? = nil) throws {
        self.key = key; self.url = url; try validate()
    }
    public func validate() throws {
        guard key != nil || url != nil else { throw BugRegistryError.invalidDocument }
        if let key {
            guard key.utf8.count <= 64, key.range(of: #"^[A-Z][A-Z0-9_]{1,31}-[1-9][0-9]{0,17}$"#, options: .regularExpression) == key.startIndex..<key.endIndex else {
                throw BugRegistryError.invalidDocument
            }
        }
        if let url {
            guard url.utf8.count <= 2_048, let parts = URLComponents(string: url), parts.scheme == "https",
                  let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil,
                  parts.query == nil, parts.fragment == nil, parts.url?.absoluteString == url,
                  !url.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) else {
                throw BugRegistryError.invalidDocument
            }
        }
    }
    private enum CodingKeys: String, CodingKey { case key, url }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(key: values.decodeIfPresent(String.self, forKey: .key), url: values.decodeIfPresent(String.self, forKey: .url))
    }
}

public struct BugRelationship: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case duplicateOf, blockedBy, relatedTo, regressionOf }
    public let kind: Kind
    public let target: BugID
    public init(kind: Kind, target: BugID) { self.kind = kind; self.target = target }
}

/// Exact operational evidence identity. Consumers must authorize and verify the artifact before reading its bytes.
public struct BugEvidenceReference: Codable, Equatable, Sendable {
    public let scope: ProjectScope
    public let environment: EnvironmentID
    public let run: RunID
    public let agent: AgentID
    public let artifact: UUID
    public let sanitizedFingerprint: ActionFingerprint
    public init(scope: ProjectScope, environment: EnvironmentID, run: RunID, agent: AgentID,
                artifact: UUID, sanitizedFingerprint: ActionFingerprint) {
        self.scope = scope; self.environment = environment; self.run = run; self.agent = agent
        self.artifact = artifact; self.sanitizedFingerprint = sanitizedFingerprint
    }
}

public struct BugRequirementRequest: Equatable, Sendable {
    public enum Role: String, Codable, Sendable { case affects, introducedBy }
    public let role: Role
    public let requirement: RequirementLinkRequest
    public init(role: Role = .affects, requirement: RequirementLinkRequest) { self.role = role; self.requirement = requirement }
}
public struct BugRequirementReference: Codable, Equatable, Sendable {
    public let role: BugRequirementRequest.Role
    public let requirement: TracedRequirement
}

public struct BugDraft: Codable, Equatable, Sendable {
    public var title: String
    public var origin: BugOrigin
    public var assessment: BugAssessment
    public var status: BugStatus
    public var environment: EnvironmentID?
    public var rootBehavior: String
    public var expectedBehavior: String
    public var actualBehavior: String
    public var reproduction: [String]
    /// Observed endpoint/component/state/error/database attributes for later deterministic duplicate comparison.
    public var details: [String: KnowledgeValue]
    public var sources: [MemorySource]
    public var evidence: [BugEvidenceReference]
    public var ticket: ExternalBugTicket?
    public var relationships: [BugRelationship]
    public var coveredBy: [TraceabilitySubject]
    public var changeReason: String
    /// Optional for compatibility with existing immutable versions. Earlier decisions remain in history.
    public internal(set) var comparisonReview: BugReviewDecision?

    public init(title: String, sources: [MemorySource], changeReason: String, origin: BugOrigin = .manual,
                assessment: BugAssessment = .reported, status: BugStatus = .open, environment: EnvironmentID? = nil,
                rootBehavior: String = "", expectedBehavior: String = "", actualBehavior: String = "",
                reproduction: [String] = [], details: [String: KnowledgeValue] = [:], evidence: [BugEvidenceReference] = [],
                ticket: ExternalBugTicket? = nil, relationships: [BugRelationship] = [], coveredBy: [TraceabilitySubject] = []) {
        self.title = title; self.sources = sources; self.changeReason = changeReason; self.origin = origin
        self.assessment = assessment; self.status = status; self.environment = environment; self.rootBehavior = rootBehavior
        self.expectedBehavior = expectedBehavior; self.actualBehavior = actualBehavior; self.reproduction = reproduction
        self.details = details; self.evidence = evidence; self.ticket = ticket; self.relationships = relationships; self.coveredBy = coveredBy
    }
    public func validate(in scope: ProjectScope, id: BugID? = nil) throws {
        try RequirementDraft.checkText(title, maximum: 1_024)
        try RequirementDraft.checkText(changeReason, maximum: 4_096)
        for text in [rootBehavior, expectedBehavior, actualBehavior] { try RequirementDraft.checkText(text, maximum: 32_768, empty: true) }
        guard (1...32).contains(sources.count), reproduction.count <= 128, evidence.count <= 64,
              Set(evidence.map(\.artifact)).count == evidence.count,
              relationships.count <= 64, Set(relationships).count == relationships.count,
              !relationships.contains(where: { $0.target == id }),
              coveredBy.count <= 64, Set(coveredBy).count == coveredBy.count,
              coveredBy.allSatisfy({ $0.kind == .automatedTest || $0.kind == .manualTest }) else { throw BugRegistryError.invalidDocument }
        for step in reproduction { try RequirementDraft.checkText(step, maximum: 8_192) }
        for source in sources {
            try source.validate(in: scope)
            if let environment, let sourceEnvironment = source.environment, environment != sourceEnvironment { throw BugRegistryError.scopeMismatch }
        }
        for reference in evidence {
            guard reference.scope == scope, environment == reference.environment else { throw BugRegistryError.scopeMismatch }
        }
        if assessment == .observed {
            guard sources.contains(where: { $0.origin == .observed }),
                  !rootBehavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !expectedBehavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !actualBehavior.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw BugRegistryError.invalidDocument }
        }
        if assessment == .blocked {
            guard relationships.contains(where: { $0.kind == .blockedBy }) else { throw BugRegistryError.invalidDocument }
        }
        var nodes = 0; try KnowledgeValue.object(details).validate(nodes: &nodes)
        try ticket?.validate()
        try comparisonReview?.validate(sourceID: id)
    }
}

public struct BugRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let scope: ProjectScope
    public let id: BugID
    public let revision: Int
    public let supersedes: Int?
    public let previousFingerprint: ActionFingerprint?
    public let createdAt: Date
    public let updatedAt: Date
    public let content: BugDraft
    public let requirements: [BugRequirementReference]
    public var fingerprint: ActionFingerprint { get throws { try .canonical(self) } }
    func validate() throws {
        guard schemaVersion == 1, (1...1_000_000).contains(revision),
              supersedes == nil || (supersedes! > 0 && supersedes! < revision),
              (supersedes == nil) == (previousFingerprint == nil),
              createdAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince1970 >= 0,
              updatedAt.timeIntervalSince1970.isFinite, updatedAt >= createdAt,
              requirements.count <= 64 else { throw BugRegistryError.invalidDocument }
        var identities = Set<String>()
        for reference in requirements {
            guard (1...1_000_000).contains(reference.requirement.version),
                  identities.insert("\(reference.role.rawValue)/\(reference.requirement.id)").inserted else { throw BugRegistryError.invalidDocument }
        }
        try content.validate(in: scope, id: id)
    }
}

public struct BugProposal: Equatable, Sendable {
    public let token: UUID
    public let candidate: BugRecord
    public let expiresAt: Date
    let requirementRequests: [BugRequirementRequest]
}
