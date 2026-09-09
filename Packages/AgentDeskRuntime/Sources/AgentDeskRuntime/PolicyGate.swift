import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

enum PolicyPreparation: Sendable {
    case allowed
    case approval(ApprovalRecord)
    case denied(PolicyEvaluation)
}
enum PolicyExecutionResult<Value: Sendable>: Sendable {
    case dryRun(PolicyEvaluation)
    case executed(Value)
}

/// Internal dispatch gate. Only trusted host code installs authenticated principals and current policies.
/// Future wire handlers must derive the concrete action and resolve its resource before calling this gate.
actor PolicyGate {
    let scope: ProjectScope
    let environmentID: EnvironmentID
    private var policy: PolicySnapshot
    private var authorities: [UUID: PolicyAuthority]
    private let store: ApprovalStore
    private let clock: @Sendable () -> Date
    private var inFlight: Set<UUID> = []

    init(policy: PolicySnapshot, authorities: [PolicyAuthority], store: ApprovalStore,
         clock: @escaping @Sendable () -> Date = { Date() }) throws {
        try policy.validate()
        guard policy.scope == store.scope, policy.environmentID == store.environmentID,
              authorities.count <= 512, Set(authorities.map(\.id)).count == authorities.count else { throw AuthorizationError.scopeMismatch }
        self.scope = policy.scope; environmentID = policy.environmentID; self.policy = policy
        self.authorities = Dictionary(uniqueKeysWithValues: authorities.map { ($0.id, $0) }); self.store = store; self.clock = clock
    }
    func installPolicy(_ updated: PolicySnapshot) throws {
        try updated.validate()
        guard updated.scope == scope, updated.environmentID == environmentID else { throw AuthorizationError.scopeMismatch }
        policy = updated
    }
    func installAuthority(_ authority: PolicyAuthority) throws {
        guard authorities[authority.id] != nil || authorities.count < 512 else { throw AuthorizationError.invalidInput }
        if let previous = authorities[authority.id], previous != authority, previous.revision == authority.revision {
            throw AuthorizationError.invalidInput
        }
        authorities[authority.id] = authority
    }
    func removeAuthority(_ id: UUID) { authorities.removeValue(forKey: id) }

    func prepare(_ action: PolicyAction, requesterID: UUID, lifetime: TimeInterval = 600) async throws -> PolicyPreparation {
        let now = try instant(); let evaluation = try evaluate(action, requesterID: requesterID, at: now)
        switch evaluation.disposition {
        case .deny: return .denied(evaluation)
        case .allow: return .allowed
        case .approval:
            guard lifetime.isFinite, lifetime > 0, lifetime <= 86_400, let authority = authorities[requesterID] else { throw AuthorizationError.invalidInput }
            let binding = try binding(requesterID)
            let record = try await store.prepare(action, requesterID: requesterID, policy: binding, at: now,
                                                 expiresAt: min(now.addingTimeInterval(lifetime), authority.expiresAt))
            guard try self.binding(requesterID) == binding else { throw AuthorizationError.stalePolicy }
            try requireAllowedContext(action, requesterID: requesterID, at: try instant())
            return .approval(record)
        }
    }
    func review(_ id: UUID, expectedAction: PolicyAction, requesterID: UUID, reviewerID: UUID,
                approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        try check(expectedAction)
        let binding: ActionFingerprint
        if approve {
            try requireAllowedContext(expectedAction, requesterID: requesterID, at: instant())
            binding = try self.binding(requesterID)
        } else {
            // Rejecting a pending effect does not require keeping its requester's execution authority alive.
            _ = try reviewingAuthority(reviewerID, action: expectedAction, at: instant())
            guard let original = try await store.approval(id), original.action == expectedAction,
                  original.requesterID == requesterID else { throw AuthorizationError.invalidApproval }
            binding = original.policyFingerprint
        }
        let now = try instant(), reviewerRevision = try reviewingAuthority(reviewerID, action: expectedAction, at: instant()).revision
        let record = try await store.review(id, action: expectedAction, policy: binding, requesterID: requesterID,
            reviewerID: reviewerID, reviewerRevision: reviewerRevision, approve: approve, expectedSequence: expectedSequence, at: now)
        if approve { guard try self.binding(requesterID) == binding else { throw AuthorizationError.stalePolicy } }
        guard authorities[reviewerID]?.revision == reviewerRevision,
              PolicyEngine.mayReview(expectedAction, authority: authorities[reviewerID], at: try instant()) else { throw AuthorizationError.denied }
        return record
    }
    func replace(_ id: UUID, original: PolicyAction, replacement: PolicyAction, requesterID: UUID, reviewerID: UUID,
                 expectedSequence: Int64, lifetime: TimeInterval = 600) async throws -> ApprovalRecord {
        let now = try instant()
        try check(original); try requireAllowedContext(replacement, requesterID: requesterID, at: now)
        guard lifetime.isFinite, lifetime > 0, lifetime <= 86_400,
              PolicyEngine.mayReview(original, authority: authorities[reviewerID], at: now),
              PolicyEngine.mayReview(replacement, authority: authorities[reviewerID], at: now),
              let requester = authorities[requesterID], let existing = try await store.approval(id) else { throw AuthorizationError.denied }
        let binding = try binding(requesterID)
        _ = try reviewingAuthority(reviewerID, action: original, at: instant())
        let reviewerRevision = try reviewingAuthority(reviewerID, action: replacement, at: instant()).revision
        try requireAllowedContext(replacement, requesterID: requesterID, at: try instant())
        let record = try await store.replace(id, original: original, replacement: replacement, requesterID: requesterID,
            originalPolicy: existing.policyFingerprint, replacementPolicy: binding, reviewerID: reviewerID, reviewerRevision: reviewerRevision,
            expectedSequence: expectedSequence, at: now, expiresAt: min(now.addingTimeInterval(lifetime), requester.expiresAt))
        guard try self.binding(requesterID) == binding, authorities[reviewerID]?.revision == reviewerRevision,
              PolicyEngine.mayReview(replacement, authority: authorities[reviewerID], at: try instant()) else { throw AuthorizationError.stalePolicy }
        return record
    }

    /// Consumes an approval durably before invoking the prepared effect. Failure/cancellation never restores it.
    /// The adapter must execute exactly this prepared action; raw model/client classifications are not accepted.
    func execute<Value: Sendable>(_ action: PolicyAction, requesterID: UUID, approvalID: UUID? = nil, dryRun: Bool = false,
                                  operation: @Sendable (PolicyAction) async throws -> Value) async throws -> PolicyExecutionResult<Value> {
        let evaluation = try evaluate(action, requesterID: requesterID, at: try instant())
        if dryRun { return .dryRun(evaluation) }
        guard evaluation.disposition != .deny else { throw AuthorizationError.denied }
        guard !inFlight.contains(action.id) else { throw AuthorizationError.alreadyUsed }
        inFlight.insert(action.id); defer { inFlight.remove(action.id) }
        let binding = try binding(requesterID)
        var consumed: ApprovalRecord?
        if evaluation.disposition == .approval || approvalID != nil {
            guard let approvalID else { throw AuthorizationError.approvalRequired }
            guard let record = try await store.approval(approvalID) else { throw AuthorizationError.missingApproval }
            guard record.action == action, record.requesterID == requesterID else { throw AuthorizationError.invalidApproval }
            guard let reviewerID = record.reviewerID, record.reviewerRevision == authorities[reviewerID]?.revision,
                  PolicyEngine.mayReview(action, authority: authorities[reviewerID], at: try instant()) else { throw AuthorizationError.approvalRequired }
            consumed = try await store.consume(approvalID, action: action, policy: binding, requesterID: requesterID,
                                                expectedSequence: record.sequence, at: try instant())
            guard consumed?.state == .consumed else { throw AuthorizationError.expired }
        }
        let dispatchTime = try instant()
        guard try self.binding(requesterID) == binding else { throw AuthorizationError.stalePolicy }
        try requireAllowedContext(action, requesterID: requesterID, at: dispatchTime)
        if let consumed {
            guard dispatchTime < consumed.expiresAt, let reviewer = consumed.reviewerID, consumed.reviewerRevision == authorities[reviewer]?.revision,
                  PolicyEngine.mayReview(action, authority: authorities[reviewer], at: dispatchTime) else { throw AuthorizationError.expired }
        }
        try Task.checkCancellation()
        return .executed(try await operation(action))
    }
    private func instant() throws -> Date {
        try Task.checkCancellation(); let now = clock()
        guard now.timeIntervalSince1970.isFinite else { throw AuthorizationError.invalidInput }
        return now
    }
    private func check(_ action: PolicyAction) throws {
        try action.validate()
        guard action.scope == scope, action.environmentID == environmentID else { throw AuthorizationError.scopeMismatch }
    }
    private func evaluate(_ action: PolicyAction, requesterID: UUID, at now: Date) throws -> PolicyEvaluation {
        try check(action)
        return try PolicyEngine.evaluate(action, policy: policy, authority: authorities[requesterID], at: now)
    }
    private func requireAllowedContext(_ action: PolicyAction, requesterID: UUID, at now: Date) throws {
        guard try evaluate(action, requesterID: requesterID, at: now).disposition != .deny else { throw AuthorizationError.denied }
    }
    private func reviewingAuthority(_ id: UUID, action: PolicyAction, at now: Date) throws -> PolicyAuthority {
        guard let authority = authorities[id], PolicyEngine.mayReview(action, authority: authority, at: now) else { throw AuthorizationError.denied }
        return authority
    }
    private func binding(_ requesterID: UUID) throws -> ActionFingerprint {
        guard let authority = authorities[requesterID] else { throw AuthorizationError.missingAuthority }
        struct Binding: Encodable { let policy: ActionFingerprint; let requester: UUID; let revision: UUID }
        return try .canonical(Binding(policy: policy.fingerprint, requester: requesterID, revision: authority.revision))
    }
}
