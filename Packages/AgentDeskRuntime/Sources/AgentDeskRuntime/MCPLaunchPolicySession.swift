#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

/// Trusted Mac host boundary. Resource resolution must validate physical project/executable identity.
/// Neither configuration nor the resource fingerprint is itself launch authority.
actor MCPLaunchPolicySession {
    private let gate: PolicyGate
    private let action: PolicyAction
    private let requesterID: UUID
    private let policyFingerprint: ActionFingerprint
    private let validate: @Sendable () async throws -> (PolicyAction, PolicySnapshot)
    private var closed = false

    private init(action: PolicyAction, policy: PolicySnapshot, authorities: [PolicyAuthority], requesterID: UUID,
                 approvals: ApprovalStore, validate: @escaping @Sendable () async throws -> (PolicyAction, PolicySnapshot)) throws {
        guard let requester = authorities.first(where: { $0.id == requesterID }), case .localUser = requester.kind else {
            throw AuthorizationError.denied
        }
        self.action = action; self.requesterID = requesterID; self.validate = validate
        policyFingerprint = try policy.fingerprint
        gate = try PolicyGate(policy: policy, authorities: authorities, store: approvals)
    }

    static func open(configurations: ProjectMCPConfigurationStore<MCPStdioConfiguration>, connectionID: UUID,
                     scope: ProjectScope, environmentID: EnvironmentID, authorities: [PolicyAuthority], requesterID: UUID,
                     approvals: ApprovalStore, currentPolicy: @escaping @Sendable () async throws -> PolicySnapshot,
                     resolveResource: @escaping @Sendable (MCPStdioConfiguration) async throws -> ActionFingerprint) async throws -> MCPLaunchPolicySession {
        guard let requester = authorities.first(where: { $0.id == requesterID }), case .localUser = requester.kind else {
            throw AuthorizationError.denied
        }
        let actionID = UUID()
        let validate: @Sendable () async throws -> (PolicyAction, PolicySnapshot) = {
            try Task.checkCancellation()
            guard let record = try await configurations.read(id: connectionID, in: scope),
                  record.configuration.enabled, record.configuration.environmentID == environmentID else {
                throw AuthorizationError.denied
            }
            let resource = try await resolveResource(record.configuration)
            let payload = try ActionFingerprint.canonical(record)
            let action = try PolicyAction(id: actionID, scope: scope, environmentID: environmentID,
                operation: .runShell, resource: resource, payload: payload)
            let policy = try await currentPolicy()
            guard policy.scope == scope, policy.environmentID == environmentID else { throw AuthorizationError.scopeMismatch }
            return (action, policy)
        }
        let (action, policy) = try await validate()
        return try Self(action: action, policy: policy, authorities: authorities, requesterID: requesterID,
            approvals: approvals, validate: validate)
    }
    private func check() async throws {
        guard !closed else { throw AuthorizationError.denied }
        let (current, policy) = try await validate()
        try Task.checkCancellation()
        guard !closed else { throw AuthorizationError.denied }
        guard current == action, try policy.fingerprint == policyFingerprint else { throw AuthorizationError.stalePolicy }
    }
    func prepare() async throws -> PolicyPreparation {
        try await check()
        return try await gate.prepare(action, requesterID: requesterID)
    }
    func review(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        try await check()
        return try await gate.review(id, expectedAction: action, requesterID: requesterID, reviewerID: requesterID,
            approve: approve, expectedSequence: expectedSequence)
    }
    func execute<Value: Sendable>(approvalID: UUID? = nil,
                                 launch: @Sendable () async throws -> Value) async throws -> PolicyExecutionResult<Value> {
        try await check()
        return try await gate.execute(action, requesterID: requesterID, approvalID: approvalID) { _ in
            try await self.check()
            return try await launch()
        }
    }
    func close() async { closed = true; await gate.removeAuthority(requesterID) }
}
#endif
