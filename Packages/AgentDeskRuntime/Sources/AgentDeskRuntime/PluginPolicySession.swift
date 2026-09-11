import AgentDeskCore
import AgentDeskPersistence
import AgentDeskPlugins
import AgentDeskSecurity
import Foundation

/// One exact prepared invocation. Owned by trusted host code, never decoded from a client request.
actor PluginPolicySession {
    private let prepared: PreparedPluginAction
    private let gate: PolicyGate
    private let requesterID: UUID
    private var authorityGeneration = UUID()
    private let policyFingerprint: ActionFingerprint
    private let validateCurrent: @Sendable () async throws -> (PreparedPluginAction, PolicySnapshot)

    init(prepared: PreparedPluginAction, policy: PolicySnapshot, permissions: PluginPermissions,
         authorities: [PolicyAuthority], requesterID: UUID, store: ApprovalStore,
         clock: @escaping @Sendable () -> Date = { Date() },
         validateCurrent: @escaping @Sendable () async throws -> (PreparedPluginAction, PolicySnapshot)) throws {
        if let requester = authorities.first(where: { $0.id == requesterID }),
           case .pairedDevice = requester.kind { throw AuthorizationError.denied }
        guard try prepared.permissionsFingerprint == ActionFingerprint.canonical(permissions) else {
            throw AuthorizationError.stalePolicy
        }
        let restricted = try permissions.restricting(policy, connectionID: prepared.connectionID,
                                                     capability: prepared.capability)
        guard prepared.action.scope == restricted.scope,
              prepared.action.environmentID == restricted.environmentID else { throw AuthorizationError.scopeMismatch }
        self.policyFingerprint = try policy.fingerprint
        self.prepared = prepared; self.requesterID = requesterID; self.validateCurrent = validateCurrent
        gate = try PolicyGate(policy: restricted, authorities: authorities, store: store, clock: clock)
    }

    func prepare() async throws -> PolicyPreparation {
        try await checkCurrent()
        return try await gate.prepare(prepared.action, requesterID: requesterID)
    }

    func review(_ approvalID: UUID, reviewerID: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        if approve { try await checkCurrent() }
        return try await gate.review(approvalID, expectedAction: prepared.action, requesterID: requesterID,
                                     reviewerID: reviewerID, approve: approve, expectedSequence: expectedSequence)
    }

    func execute<Value: Sendable>(approvalID: UUID? = nil,
                                  operation: @Sendable (PolicyAction) async throws -> Value) async throws -> PolicyExecutionResult<Value> {
        let generation = authorityGeneration
        try await checkCurrent(expectedAuthority: generation)
        return try await gate.execute(prepared.action, requesterID: requesterID, approvalID: approvalID) { action in
            try await self.checkCurrent(expectedAuthority: generation)
            return try await operation(action)
        }
    }

    func installAuthority(_ authority: PolicyAuthority) async throws {
        authorityGeneration = UUID()
        if authority.id == requesterID, case .pairedDevice = authority.kind {
            await gate.removeAuthority(authority.id)
            throw AuthorizationError.denied
        }
        try await gate.installAuthority(authority)
    }
    func removeAuthority(_ id: UUID) async {
        authorityGeneration = UUID()
        await gate.removeAuthority(id)
    }

    private func checkCurrent(expectedAuthority: UUID? = nil) async throws {
        try Task.checkCancellation()
        let current = try await validateCurrent()
        guard current.0.action == prepared.action, try current.1.fingerprint == policyFingerprint else { throw AuthorizationError.stalePolicy }
        guard expectedAuthority == nil || expectedAuthority == authorityGeneration else {
            throw AuthorizationError.stalePolicy
        }
        try Task.checkCancellation()
    }
}
