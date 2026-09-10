import Foundation

/// Trusted local administrative boundary. Model intake and external publication need separate policy/redaction gates.
public actor ProjectBugStore {
    public nonisolated let scope: ProjectScope
    private let files: BugRegistryFiles
    private let requirements: ProjectRequirementStore
    private var proposals: [UUID: BugProposal] = [:]
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
        let files = files, id = id ?? BugID()
        let existing = try files.root.withLock { try files.validate(requested); return try files.read(id).first }
        guard existing?.revision == expectedRevision else { throw BugRegistryError.staleRevision }
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
        guard proposals.count < 16 else { throw BugRegistryError.limitExceeded }
        let proposal = BugProposal(token: UUID(), candidate: candidate, expiresAt: now.addingTimeInterval(300), requirementRequests: checks)
        proposals[proposal.token] = proposal
        return proposal
    }
    public func cancel(_ proposal: BugProposal) { proposals.removeValue(forKey: proposal.token) }
    public func publishReviewed(_ proposal: BugProposal, in requested: ProjectScope) async throws -> BugRecord {
        guard requested == scope else { throw BugRegistryError.scopeMismatch }
        let now = try instant()
        guard proposals[proposal.token] == proposal, proposal.candidate.scope == scope,
              now >= proposal.candidate.updatedAt, now < proposal.expiresAt else { throw BugRegistryError.invalidReview }
        proposals.removeValue(forKey: proposal.token)
        let files = files
        return try await requirements.withBugReferences(proposal.requirementRequests, in: scope,
            environment: proposal.candidate.content.environment) { resolved in
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
