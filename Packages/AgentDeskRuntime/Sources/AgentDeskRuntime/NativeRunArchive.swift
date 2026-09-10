#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

/// Local evidence access without a provider, repository grant, recovery or execution lease.
/// The application supplies current configuration; every read checks current policy twice.
public actor NativeRunArchive: RunEvidenceReading {
    private let database: URL
    private let scope: ProjectScope
    private let agentID: AgentID
    private let environmentID: EnvironmentID
    private let authority: PolicyAuthority
    private let current: @Sendable () async throws -> EffectiveExecutionConfiguration

    public init(database: URL, scope: ProjectScope, agentID: AgentID, environmentID: EnvironmentID,
                current: @escaping @Sendable () async throws -> EffectiveExecutionConfiguration) throws {
        self.database = database; self.scope = scope; self.agentID = agentID; self.environmentID = environmentID
        self.current = current
        authority = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environmentID],
            operations: [.readEvidence], expiresAt: Date().addingTimeInterval(1_800))
    }
    public func runs(before: RunID? = nil, limit: Int = 25) async throws -> [StoredRun] {
        struct Query: Encodable { let agent: AgentID; let before: RunID?; let limit: Int }
        let payload = try ActionFingerprint.canonical(Query(agent: agentID, before: before, limit: limit))
        try await authorize(run: nil, payload: payload)
        guard (1...100).contains(limit) else { throw OperationalStoreError.invalidInput }
        guard FileManager.default.fileExists(atPath: database.path) else {
            guard before == nil else { throw OperationalStoreError.invalidInput }
            try await authorize(run: nil, payload: payload)
            return []
        }
        let store = try OperationalStore(database: database, workspaceID: scope.workspaceID)
        let result = try await store.boundRuns(in: scope, environmentID: environmentID, agentID: agentID, before: before, limit: limit)
        try await authorize(run: nil, payload: payload)
        return result
    }
    public func evidenceRecords(for run: RunID, after: Int64 = 0, limit: Int = 100) async throws -> [EvidenceRecord] {
        let store = try await evidence(run)
        let result = try await store.records(after: after, limit: limit)
        try await authorize(run: run, payload: .canonical(run))
        return result
    }
    public func artifact(_ id: UUID, for run: RunID) async throws -> StoredEvidenceContent? {
        let store = try await evidence(run), result = try await store.artifact(id)
        try await authorize(run: run, payload: .canonical(id))
        return result
    }
    public func trace(_ id: UUID, for run: RunID) async throws -> StoredTrace? {
        let store = try await evidence(run), result = try await store.trace(id)
        try await authorize(run: run, payload: .canonical(id))
        return result
    }
    private func evidence(_ run: RunID) async throws -> EvidenceStore {
        try await authorize(run: run, payload: .canonical(run))
        guard FileManager.default.fileExists(atPath: database.path) else { throw EvidenceStoreError.unregisteredRun }
        let context = RedactionContext(scope: scope, environmentID: environmentID, runID: run)
        let store = try EvidenceStore(database: database, context: context, agentID: agentID)
        guard let binding = try await store.binding(), binding.context == context, binding.agentID == agentID else {
            throw AuthorizationError.scopeMismatch
        }
        return store
    }
    private func authorize(run: RunID?, payload: ActionFingerprint) async throws {
        try Task.checkCancellation()
        let configuration = try await current()
        guard configuration.scope == scope, configuration.agentID == agentID,
              configuration.environment.id == environmentID else { throw AuthorizationError.scopeMismatch }
        let action = try PolicyAction(scope: scope, environmentID: environmentID, runID: run,
            agentID: run == nil ? nil : agentID, operation: .readEvidence,
            resource: .canonical(scope), payload: payload)
        switch try PolicyEngine.evaluate(action, policy: configuration.policy, authority: authority, at: Date()).disposition {
        case .allow: break
        case .approval: throw AuthorizationError.approvalRequired
        case .deny: throw AuthorizationError.denied
        }
        try Task.checkCancellation()
    }
}
#endif
