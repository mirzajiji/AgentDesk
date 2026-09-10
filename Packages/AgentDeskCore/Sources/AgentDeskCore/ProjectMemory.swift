import Foundation

public enum MemoryEntity: Sendable {}
public typealias MemoryID = EntityID<MemoryEntity>
public enum MemoryKind: String, Codable, CaseIterable, Sendable { case confirmed, note, inbox }
public enum MemoryTopic: String, Codable, CaseIterable, Sendable {
    case projectDescription, businessRule, apiBehavior, stateTransition, environmentRule, testExpectation
    case architecture, qaDecision, discoveredBehavior, terminology, documentation, unclassified
}
public enum MemoryDisposition: String, Codable, Sendable { case active, archived, ignored }

public struct MemorySource: Codable, Equatable, Sendable {
    public enum Origin: String, Codable, Sendable { case observed, humanStatement, interpretation }
    public let scope: ProjectScope
    public let origin: Origin
    public let label: String
    /// Inert provenance text, never automatically fetched or interpreted as a path.
    public let reference: String?
    public let environment: EnvironmentID?
    public let run: RunID?
    public let agent: AgentID?
    public let capturedAt: Date
    public init(scope: ProjectScope, origin: Origin, label: String, reference: String? = nil,
                environment: EnvironmentID? = nil, run: RunID? = nil, agent: AgentID? = nil, capturedAt: Date) {
        self.scope = scope; self.origin = origin; self.label = label; self.reference = reference
        self.environment = environment; self.run = run; self.agent = agent; self.capturedAt = capturedAt
    }
    func validate(in scope: ProjectScope) throws {
        guard self.scope == scope else { throw RequirementError.scopeMismatch }
        guard capturedAt.timeIntervalSince1970.isFinite, capturedAt.timeIntervalSince1970 >= 0,
              run == nil || environment != nil, agent == nil || run != nil else { throw RequirementError.invalidDocument }
        try RequirementDraft.checkText(label, maximum: 1_024)
        if let reference { try RequirementDraft.checkText(reference, maximum: 2_048) }
    }
}

public struct MemoryDraft: Codable, Equatable, Sendable {
    public var knowledgePath: KnowledgePath?
    public var kind: MemoryKind
    public var topic: MemoryTopic
    public var title: String
    public var body: String
    public var structured: [String: KnowledgeValue]
    public var sources: [MemorySource]
    public var environmentScope: [EnvironmentID]
    public var tags: [String]
    public var disposition: MemoryDisposition
    public var changeReason: String
    public init(kind: MemoryKind, topic: MemoryTopic = .unclassified, title: String, body: String,
                sources: [MemorySource], structured: [String: KnowledgeValue] = [:],
                environmentScope: [EnvironmentID] = [], tags: [String] = [], disposition: MemoryDisposition = .active,
                changeReason: String, knowledgePath: KnowledgePath? = nil) {
        self.knowledgePath = knowledgePath
        self.kind = kind; self.topic = topic; self.title = title; self.body = body; self.sources = sources
        self.structured = structured; self.environmentScope = environmentScope; self.tags = tags
        self.disposition = disposition; self.changeReason = changeReason
    }
    public func validate(in scope: ProjectScope) throws {
        try RequirementDraft.checkText(title, maximum: 1_024)
        try RequirementDraft.checkText(body, maximum: 65_536)
        try RequirementDraft.checkText(changeReason, maximum: 4_096)
        guard (1...32).contains(sources.count), tags.count <= 32, Set(tags).count == tags.count,
              environmentScope.count <= 128, Set(environmentScope).count == environmentScope.count,
              disposition != .ignored || kind == .inbox,
              kind != .confirmed || topic != .unclassified else { throw RequirementError.invalidDocument }
        for source in sources { try source.validate(in: scope) }
        for tag in tags { try RequirementDraft.checkText(tag, maximum: 96) }
        var nodes = 0; try KnowledgeValue.object(structured).validate(nodes: &nodes)
    }
}

public struct MemoryRecord: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let scope: ProjectScope
    public let id: MemoryID
    public let revision: Int
    public let supersedes: Int?
    public let previousFingerprint: ActionFingerprint?
    public let createdAt: Date
    public let updatedAt: Date
    public let content: MemoryDraft
    public var fingerprint: ActionFingerprint { get throws { try ActionFingerprint.canonical(self) } }
    func validate() throws {
        guard schemaVersion == 1, (1...1_000_000).contains(revision),
              supersedes == nil || (supersedes! > 0 && supersedes! < revision),
              (supersedes == nil) == (previousFingerprint == nil),
              createdAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince1970 >= 0,
              updatedAt.timeIntervalSince1970.isFinite, updatedAt >= createdAt else { throw RequirementError.invalidDocument }
        try content.validate(in: scope)
    }
}

public struct MemoryProposal: Equatable, Sendable {
    public let token: UUID
    public let candidate: MemoryRecord
    public let expiresAt: Date
}
