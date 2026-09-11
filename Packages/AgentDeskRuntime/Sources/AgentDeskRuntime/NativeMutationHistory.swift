import AgentDeskCore
import AgentDeskSecurity
import AgentDeskPersistence
import Foundation

/// Local-user operational browsing. This service grants no mutation or retry authority.
public actor NativeMutationHistory {
    public nonisolated let scope: ProjectScope
    public nonisolated let environmentID: EnvironmentID
    private let store: MutationAttemptStore
    private let gate: PolicyGate
    private let currentPolicy: (@Sendable () async throws -> PolicySnapshot)?
    private let userID: UUID
    private var closed = false

    public init(database: URL, scope: ProjectScope, environmentID: EnvironmentID,
                policy: PolicySnapshot, user: PolicyAuthority,
                currentPolicy: (@Sendable () async throws -> PolicySnapshot)? = nil) throws {
        guard case .localUser = user.kind else { throw AuthorizationError.denied }
        guard policy.scope == scope, policy.environmentID == environmentID else { throw AuthorizationError.scopeMismatch }
        self.currentPolicy = currentPolicy
        self.scope = scope; self.environmentID = environmentID; userID = user.id
        store = try MutationAttemptStore(database: database, scope: scope, environmentID: environmentID)
        gate = try PolicyGate(policy: policy, authorities: [user],
            store: ApprovalStore(database: database, scope: scope, environmentID: environmentID))
    }
    public func page(after cursor: UUID? = nil, limit: Int = 50) async throws -> MutationAttemptPage {
        try checkOpen()
        struct Query: Encodable { let operation = "mutation-history"; let cursor: UUID?; let limit: Int }
        let action = try PolicyAction(scope: scope, environmentID: environmentID, operation: .readEvidence,
            resource: .canonical("mutation-attempt-ledger"), payload: .canonical(Query(cursor: cursor, limit: limit)))
        try await refreshPolicy()
        try await gate.authorizePreparationRead(action, requesterID: userID)
        let page = try await store.page(after: cursor, limit: limit)
        try checkOpen()
        try await refreshPolicy()
        try await gate.authorizePreparationRead(action, requesterID: userID)
        return page
    }
    private func refreshPolicy() async throws {
        if let currentPolicy { try await gate.installPolicy(currentPolicy()) }
        try checkOpen()
    }
    public func installPolicy(_ policy: PolicySnapshot) async throws {
        try checkOpen()
        try await gate.installPolicy(policy)
    }
    public func close() { closed = true }
    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !closed else { throw AuthorizationError.denied }
    }
}
