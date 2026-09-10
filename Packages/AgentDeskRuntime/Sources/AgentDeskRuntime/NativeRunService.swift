#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

/// Trusted native application boundary. Do not expose its review/policy methods to model or mobile tools.
/// A service binds one agent/environment and retains the project owner until explicit shutdown.
public actor NativeRunService {
    public nonisolated let scope: ProjectScope
    public nonisolated let agentID: AgentID
    public nonisolated let environmentID: EnvironmentID
    public nonisolated let recoveredRunCount: Int
    private let database: URL
    private let coordinator: RunCoordinator
    private let gate: PolicyGate
    private let requesterID: UUID
    private let reviewerID: UUID
    private let resource: ExecutionResource
    private let directory: URL
    private let captureRepository: Bool
    private let makeRedactor: @Sendable (RedactionContext) async throws -> ContentRedactor
    private var closed = false
    private var repositoryAccess: RepositoryAccess?

    /// The executable comes from validated native Codex settings. The directory must be accessible
    /// under the main app's user-selected read grant; the caller retains that grant until shutdown.
    public static func open(database: URL, directory: URL, executable: URL, configuration: EffectiveExecutionConfiguration,
                            captureRepository: Bool,
                            redactor: @escaping @Sendable (RedactionContext) async throws -> ContentRedactor = { try ContentRedactor(context: $0) }) async throws -> NativeRunService {
        let provider = try CodexHostExecutionProvider(scope: configuration.scope, directory: directory, executable: executable)
        return try await open(database: database, directory: directory, configuration: configuration, captureRepository: captureRepository,
                              redactor: redactor, provider: provider)
    }
    /// Retains the selected-folder grant and registration lease until the service has shut down.
    public static func open(database: URL, repository: RepositoryAccess, executable: URL,
                            configuration: EffectiveExecutionConfiguration,
                            redactor: @escaping @Sendable (RedactionContext) async throws -> ContentRedactor = { try ContentRedactor(context: $0) }) async throws -> NativeRunService {
        guard repository.registration.scope == configuration.scope else { throw RunCoordinatorError.invalidPreparation }
        let service = try await open(database: database, directory: repository.directory, executable: executable,
            configuration: configuration, captureRepository: true, redactor: redactor)
        await service.retain(repository)
        return service
    }
    private func retain(_ access: RepositoryAccess) { repositoryAccess = access }
    static func open(database: URL, directory: URL, configuration: EffectiveExecutionConfiguration, captureRepository: Bool,
                     redactor: @escaping @Sendable (RedactionContext) async throws -> ContentRedactor = { try ContentRedactor(context: $0) },
                     provider: any ExecutionProvider) async throws -> NativeRunService {
        let requesterID = UUID(), reviewerID = UUID(), scope = configuration.scope, environmentID = configuration.environment.id
        // This local session expires; neither provider text nor serialized requests can renew it.
        let expiry = Date().addingTimeInterval(TimeInterval(configuration.timeoutSeconds + 1_800))
        let requester = try PolicyAuthority(id: requesterID, kind: .agent(configuration.agentID), scopes: [scope], environments: [environmentID],
            operations: [.readEvidence, .runReadOnlyAgent], expiresAt: expiry)
        let reviewer = try PolicyAuthority(id: reviewerID, kind: .localUser, scopes: [scope], environments: [environmentID],
            operations: [.readEvidence, .runReadOnlyAgent], canApprove: true, expiresAt: expiry)
        let approvals = try ApprovalStore(database: database, scope: scope, environmentID: environmentID)
        let gate = try PolicyGate(policy: configuration.policy, authorities: [requester, reviewer], store: approvals)
        let coordinator = try RunCoordinator(database: database, scope: scope, environmentID: environmentID, gate: gate, provider: provider)
        do {
            let recovered = try await coordinator.recoverInterruptedRuns()
            return NativeRunService(database: database, directory: directory, scope: scope, agentID: configuration.agentID,
                environmentID: environmentID, recoveredRunCount: recovered, coordinator: coordinator, gate: gate,
                requesterID: requesterID, reviewerID: reviewerID, resource: provider.resource,
                captureRepository: captureRepository, redactor: redactor)
        } catch { await coordinator.shutdown(); throw error }
    }
    private init(database: URL, directory: URL, scope: ProjectScope, agentID: AgentID, environmentID: EnvironmentID, recoveredRunCount: Int,
                 coordinator: RunCoordinator, gate: PolicyGate, requesterID: UUID, reviewerID: UUID, resource: ExecutionResource,
                 captureRepository: Bool, redactor: @escaping @Sendable (RedactionContext) async throws -> ContentRedactor) {
        self.database = database; self.directory = directory; self.scope = scope; self.agentID = agentID; self.environmentID = environmentID
        self.recoveredRunCount = recoveredRunCount; self.coordinator = coordinator; self.gate = gate
        self.requesterID = requesterID; self.reviewerID = reviewerID; self.resource = resource
        self.captureRepository = captureRepository; self.makeRedactor = redactor
    }
    public func prepare(instructions: ComposedInstructions, configuration: EffectiveExecutionConfiguration, task: String) async throws -> PreparedRun {
        try checkOpen()
        guard configuration.agentID == agentID else { throw RunCoordinatorError.invalidPreparation }
        let repository: (@Sendable (RedactionContext, ContentRedactor) async throws -> any RunRepositoryCapturing)?
        if captureRepository {
            let directory = directory
            repository = { context, redactor in try GitRepositoryCapture(root: directory, context: context, redactor: redactor) }
        } else { repository = nil }
        return try await coordinator.prepare(instructions: instructions, configuration: configuration, task: task,
            requesterID: requesterID, location: RunLocationSnapshot(scope: scope, selectedDirectory: directory.path,
                registrationID: repositoryAccess?.registration.id, registrationRevision: repositoryAccess?.registration.revision),
            redactor: makeRedactor, repository: repository)
    }
    /// Revalidates the displayed native context before any preparation record or provider work.
    public func prepare(context: ProjectRunContext, setup: ProjectExecutionSetupService, task: String) async throws -> PreparedRun {
        try checkOpen()
        guard context.scope == scope, setup.scope == scope else { throw RunCoordinatorError.invalidPreparation }
        try await setup.validate(context)
        return try await prepare(instructions: context.instructions, configuration: context.configuration, task: task)
    }
    public func start(_ prepared: PreparedRun) async throws -> RunExecution {
        try checkOpen(); return try await coordinator.start(prepared.token)
    }
    public func discard(_ prepared: PreparedRun) async throws -> RunOutcome {
        try checkOpen(); return try await coordinator.discard(prepared.token)
    }
    /// Called only for an explicit local user's review of the displayed action and approval sequence.
    public func review(_ prepared: PreparedRun, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        try checkOpen()
        guard let approval = prepared.approval else { throw AuthorizationError.missingApproval }
        return try await gate.review(approval.id, expectedAction: prepared.action, requesterID: requesterID,
            reviewerID: reviewerID, approve: approve, expectedSequence: expectedSequence)
    }
    /// The trusted configuration owner propagates policy edits here; active runs observe revocation.
    public func installPolicy(_ policy: PolicySnapshot) async throws { try checkOpen(); try await gate.installPolicy(policy) }
    public func run(_ id: RunID) async throws -> StoredRun? {
        _ = try await evidence(for: id)
        return try await coordinator.lifecycle.run(id, in: scope)
    }
    public func progress(for id: RunID) async throws -> RunWorkPlan? {
        _ = try await evidence(for: id)
        return try await coordinator.lifecycle.progress(for: id, in: scope)
    }
    public func history(for id: RunID, after sequence: Int64 = 0, limit: Int = 256) async throws -> [StoredRunEvent] {
        _ = try await evidence(for: id)
        return try await coordinator.lifecycle.history(for: id, in: scope, after: sequence, limit: limit)
    }
    public func evidenceRecords(for id: RunID, after sequence: Int64 = 0, limit: Int = 100) async throws -> [EvidenceRecord] {
        try await evidence(for: id).records(after: sequence, limit: limit)
    }
    public func artifact(_ artifactID: UUID, for id: RunID) async throws -> StoredEvidenceContent? {
        try await evidence(for: id).artifact(artifactID)
    }
    public func trace(_ traceID: UUID, for id: RunID) async throws -> StoredTrace? {
        try await evidence(for: id).trace(traceID)
    }
    public func shutdown() async { closed = true; await coordinator.shutdown(); repositoryAccess = nil }
    private func evidence(for id: RunID) async throws -> EvidenceStore {
        try checkOpen()
        let action = try PolicyAction(scope: scope, environmentID: environmentID, runID: id, agentID: agentID,
            operation: .readEvidence, resource: resource.fingerprint, payload: .canonical(id))
        try await gate.authorizePreparationRead(action, requesterID: requesterID)
        let evidence = try EvidenceStore(database: database, context: RedactionContext(scope: scope, environmentID: environmentID, runID: id), agentID: agentID)
        guard try await evidence.binding() != nil else { throw RunCoordinatorError.invalidPreparation }
        try checkOpen(); return evidence
    }
    private func checkOpen() throws { try Task.checkCancellation(); guard !closed else { throw RunCoordinatorError.closed } }
}
#endif
