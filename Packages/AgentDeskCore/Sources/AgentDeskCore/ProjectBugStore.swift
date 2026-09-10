import Foundation

/// Trusted local administrative boundary. Model intake and external publication need separate policy/redaction gates.
public actor ProjectBugStore {
    public nonisolated let scope: ProjectScope
    private let files: BugRegistryFiles
    private let requirements: ProjectRequirementStore
    private var proposals: [UUID: BugProposal] = [:]
    private var comparisonSnapshots: [UUID: BugComparisonSnapshot] = [:]
    init(scope: ProjectScope, root: ConfigurationDirectory, workspace: ConfigurationDirectory,
         project: ConfigurationDirectory, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.scope = scope
        files = BugRegistryFiles(scope: scope, root: root, workspace: workspace, project: project, clock: clock)
        requirements = ProjectRequirementStore(scope: scope, root: root, workspace: workspace, project: project)
    }
    /// Nil requirement requests preserve creation references on edits. Explicit requests resolve current active
    /// requirements by default; historical reproduction must specify a version.
    public func prepare(_ draft: BugDraft, requirements requests: [BugRequirementRequest]? = nil,
                        id: BugID? = nil, expectedRevision: Int? = nil, in requested: ProjectScope) async throws -> BugProposal {
        try await prepareDraft(draft, requirements: requests, id: id, expectedRevision: expectedRevision, in: requested, allowsDecision: false)
    }
    private func prepareDraft(_ draft: BugDraft, requirements requests: [BugRequirementRequest]? = nil,
                              id: BugID? = nil, expectedRevision: Int? = nil, in requested: ProjectScope,
                              allowsDecision: Bool) async throws -> BugProposal {
        let files = files, id = id ?? BugID()
        let existing = try files.root.withLock { try files.validate(requested); return try files.read(id).first }
        guard existing?.revision == expectedRevision else { throw BugRegistryError.staleRevision }
        guard allowsDecision || draft.comparisonReview == existing?.content.comparisonReview else { throw BugRegistryError.invalidReview }
        try draft.validate(in: scope, id: id)
        let checks = requests ?? (existing?.requirements.map {
            BugRequirementRequest(role: $0.role, requirement: .init(id: $0.requirement.id, historicalVersion: $0.requirement.version))
        } ?? [])
        let candidate = try await requirements.withBugReferences(checks, in: requested, environment: draft.environment) { resolved in
            try files.validate(requested)
            let references: [BugRequirementReference]
            if requests == nil, let existing {
                guard Self.matches(existing.requirements, resolved) else { throw BugRegistryError.unavailableReference }
                references = existing.requirements
            } else { references = resolved }
            return try files.candidate(draft, requirements: references, id: id, expected: expectedRevision)
        }
        try Task.checkCancellation()
        let now = try instant()
        proposals = proposals.filter { $0.value.expiresAt > now }
        comparisonSnapshots = comparisonSnapshots.filter { proposals[$0.key] != nil }
        guard proposals.count < 16 else { throw BugRegistryError.limitExceeded }
        let proposal = BugProposal(token: UUID(), candidate: candidate, expiresAt: now.addingTimeInterval(300), requirementRequests: checks)
        proposals[proposal.token] = proposal
        return proposal
    }
    public func cancel(_ proposal: BugProposal) { proposals.removeValue(forKey: proposal.token); comparisonSnapshots.removeValue(forKey: proposal.token) }
    /// Creates an exact local review proposal; publication still requires publishReviewed.
    public func prepareComparisonDecision(_ snapshot: BugComparisonSnapshot, incomingID: BugID, existingID: BugID,
                                          resolution: BugReviewDecision.Resolution, reason: String,
                                          in requested: ProjectScope) async throws -> BugProposal {
        try await validate(snapshot, in: requested)
        guard let incoming = snapshot.records.first(where: { $0.record.id == incomingID }),
              let existing = snapshot.records.first(where: { $0.record.id == existingID }),
              BugComparison.readiness(incoming) == nil else { throw BugRegistryError.invalidReview }
        let comparison = try BugComparison.compare(incoming, with: existing)
        if resolution == .duplicate {
            guard existing.record.content.assessment == .observed, !existing.staleRequirements,
                  [.duplicate, .possibleDuplicate].contains(comparison.classification) else { throw BugRegistryError.invalidReview }
        }
        var draft = incoming.record.content
        draft.comparisonReview = .init(sourceID: incomingID, sourceRevision: incoming.record.revision,
            existingID: existingID, existingRevision: existing.record.revision, suggested: comparison.classification,
            resolution: resolution, reason: reason)
        draft.changeReason = reason
        draft.relationships.removeAll { $0.target == existingID && [.duplicateOf, .relatedTo].contains($0.kind) }
        if resolution != .distinct { draft.relationships.append(.init(kind: resolution == .duplicate ? .duplicateOf : .relatedTo, target: existingID)) }
        let proposal = try await prepareDraft(draft, id: incomingID, expectedRevision: incoming.record.revision, in: requested, allowsDecision: true)
        do { try await validate(snapshot, in: requested) }
        catch { cancel(proposal); throw error }
        comparisonSnapshots[proposal.token] = snapshot
        return proposal
    }
    public func publishReviewed(_ proposal: BugProposal, in requested: ProjectScope) async throws -> BugRecord {
        guard requested == scope else { throw BugRegistryError.scopeMismatch }
        let now = try instant()
        guard proposals[proposal.token] == proposal, proposal.candidate.scope == scope,
              now >= proposal.candidate.updatedAt, now < proposal.expiresAt else { throw BugRegistryError.invalidReview }
        proposals.removeValue(forKey: proposal.token)
        let comparisonSnapshot = comparisonSnapshots.removeValue(forKey: proposal.token)
        let files = files
        return try await requirements.withBugReferences(proposal.requirementRequests, in: scope,
            environment: proposal.candidate.content.environment, comparison: comparisonSnapshot.map { (files, $0) }) { resolved in
            try files.validate(requested)
            let now = files.clock()
            guard now.timeIntervalSince1970.isFinite, now >= proposal.candidate.updatedAt, now < proposal.expiresAt else {
                throw BugRegistryError.invalidReview
            }
            guard Self.matches(proposal.candidate.requirements, resolved) else { throw BugRegistryError.unavailableReference }
            return try files.publish(proposal.candidate)
        }
    }
    public func record(_ id: BugID, in requested: ProjectScope) throws -> BugRecord? {
        try files.root.withLock { try files.validate(requested); return try files.read(id).first }
    }
    public func history(_ id: BugID, in requested: ProjectScope) throws -> [BugRecord] {
        try files.root.withLock { try files.validate(requested); return try files.read(id) }
    }
    /// Includes archived records so an existing ticket cannot disappear from duplicate checks.
    /// Exceeding the bound fails rather than silently presenting a partial search as exhaustive.
    public func comparisonSnapshot(in requested: ProjectScope, environment: EnvironmentID) async throws -> BugComparisonSnapshot {
        try await requirements.bugComparisonSnapshot(files: files, in: requested, environment: environment)
    }
    public func validate(_ snapshot: BugComparisonSnapshot, in requested: ProjectScope) async throws {
        guard snapshot.scope == requested else { throw BugRegistryError.scopeMismatch }
        let current = try await comparisonSnapshot(in: requested, environment: snapshot.environment)
        guard current.fingerprint == snapshot.fingerprint else { throw BugRegistryError.staleRevision }
    }
    /// Resolves consecutive explicit decisions on the same unchanged finding. An ordinary edit ends
    /// the chain; an old decision cannot silently revive after evidence changes and later reverts.
    public func comparisonDecisions(for incomingID: BugID, snapshot: BugComparisonSnapshot,
                                    in requested: ProjectScope) async throws -> [BugReviewDecision] {
        try await validate(snapshot, in: requested)
        return try files.root.withLock {
            try files.validate(requested)
            guard let incoming = snapshot.records.first(where: { $0.record.id == incomingID }) else { throw BugRegistryError.unavailableReference }
            let history = try files.read(incomingID)
            guard try history.first?.fingerprint == incoming.record.fingerprint else { throw BugRegistryError.staleRevision }
            var result: [BugReviewDecision] = [], seen = Set<BugID>()
            for record in history {
                guard let decision = record.content.comparisonReview, decision.sourceRevision == record.supersedes,
                      let source = history.first(where: { $0.revision == decision.sourceRevision }),
                      decision != source.content.comparisonReview else { break }
                guard try Self.decisionBasis(source) == Self.decisionBasis(incoming.record) else { break }
                if seen.insert(decision.existingID).inserted,
                   snapshot.records.contains(where: { $0.record.id == decision.existingID && $0.record.revision == decision.existingRevision }) {
                    result.append(decision)
                }
            }
            return result
        }
    }
    private nonisolated static func decisionBasis(_ record: BugRecord) throws -> ActionFingerprint {
        struct Basis: Encodable { let content: BugDraft; let requirements: [BugRequirementReference] }
        var content = record.content; content.comparisonReview = nil; content.changeReason = "Comparison basis"
        content.relationships.removeAll { [.duplicateOf, .relatedTo].contains($0.kind) }
        return try .canonical(Basis(content: content, requirements: record.requirements))
    }
    public func list(in requested: ProjectScope, statuses: Set<BugStatus> = [.open, .resolved, .closed],
                     environment: EnvironmentID? = nil, registered: Bool? = nil,
                     after: BugID? = nil, limit: Int = 50) throws -> [BugRecord] {
        try files.root.withLock {
            try files.validate(requested)
            guard (1...100).contains(limit) else { throw BugRegistryError.limitExceeded }
            let parent: ConfigurationDirectory
            do { parent = try files.project.child("Memory").child("Bugs") } catch ScopedFileError.notFound { return [] }
            var result: [BugRecord] = []
            for name in try parent.names() where !name.hasPrefix(".") {
                try Task.checkCancellation()
                guard let id = BugID(rawValue: name), id.rawValue == name else { throw BugRegistryError.invalidDocument }
                if let after, name <= after.rawValue { continue }
                guard let value = try files.read(id).first, statuses.contains(value.content.status) else { continue }
                if let environment, value.content.environment != environment { continue }
                if let registered, (value.content.ticket != nil) != registered { continue }
                result.append(value); if result.count == limit { break }
            }
            return result
        }
    }
    private func instant() throws -> Date {
        let now = files.clock()
        guard now.timeIntervalSince1970.isFinite, now.timeIntervalSince1970 >= 0 else { throw BugRegistryError.invalidReview }
        return now
    }
    private nonisolated static func matches(_ lhs: [BugRequirementReference], _ rhs: [BugRequirementReference]) -> Bool {
        lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { a, b in
            a.role == b.role && a.requirement.id == b.requirement.id && a.requirement.version == b.requirement.version && a.requirement.fingerprint == b.requirement.fingerprint
        }
    }
}
