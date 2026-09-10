#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

/// Trusted native application boundary. Do not expose its review/policy methods to model or mobile tools.
/// A service binds one agent/environment and retains the project owner until explicit shutdown.
public actor NativeRunService: RunEvidenceReading {
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
    public func prepare(instructions: ComposedInstructions, configuration: EffectiveExecutionConfiguration, task: String,
                        knowledgeCatalog: WorkspaceCatalog? = nil) async throws -> PreparedRun {
        try checkOpen()
        guard configuration.agentID == agentID else { throw RunCoordinatorError.invalidPreparation }
        let repository: (@Sendable (RedactionContext, ContentRedactor) async throws -> any RunRepositoryCapturing)?
        if captureRepository {
            let directory = directory
            repository = { context, redactor in try GitRepositoryCapture(root: directory, context: context, redactor: redactor) }
        } else { repository = nil }
        let knowledge: (@Sendable (ContentRedactor) async throws -> PreparedKnowledgeContext)?
        if let selection = configuration.knowledge {
            guard let catalog = knowledgeCatalog else { throw RunCoordinatorError.invalidPreparation }
            let database = database, scope = scope, environment = environmentID
            knowledge = { redactor in
                let memory = try await catalog.memoryStore(in: scope)
                let requirements = try await catalog.requirementStore(in: scope)
                let index = try KnowledgeSearchIndex(database: database, scope: scope, environment: environment)
                _ = try await index.rebuild(memory: memory, requirements: requirements, redactor: redactor)
                let service = try KnowledgeContextService(memory: memory, requirements: requirements, environment: environment, search: index)
                return try await service.prepare(selection, redactor: redactor)
            }
        } else { knowledge = nil }
        return try await coordinator.prepare(instructions: instructions, configuration: configuration, task: task,
            requesterID: requesterID, location: RunLocationSnapshot(scope: scope, selectedDirectory: directory.path,
                registrationID: repositoryAccess?.registration.id, registrationRevision: repositoryAccess?.registration.revision),
            redactor: makeRedactor, knowledge: knowledge, repository: repository)
    }
    /// Revalidates the displayed native context before any preparation record or provider work.
    public func prepare(context: ProjectRunContext, setup: ProjectExecutionSetupService, task: String,
                        knowledgeCatalog: WorkspaceCatalog? = nil) async throws -> PreparedRun {
        try checkOpen()
        guard context.scope == scope, setup.scope == scope else { throw RunCoordinatorError.invalidPreparation }
        try await setup.validate(context)
        return try await prepare(instructions: context.instructions, configuration: context.configuration, task: task, knowledgeCatalog: knowledgeCatalog)
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
    /// Native local-user browsing, restricted to this service's exact agent/environment.
    public func runs(before cursor: RunID? = nil, limit: Int = 50) async throws -> [StoredRun] {
        try checkOpen()
        struct Query: Encodable { let agentID: AgentID; let before: RunID?; let limit: Int }
        let action = try PolicyAction(scope: scope, environmentID: environmentID, operation: .readEvidence,
            resource: resource.fingerprint, payload: .canonical(Query(agentID: agentID, before: cursor, limit: limit)))
        try await gate.authorizePreparationRead(action, requesterID: reviewerID)
        let store = try OperationalStore(database: database, workspaceID: scope.workspaceID)
        let runs = try await store.boundRuns(in: scope, environmentID: environmentID, agentID: agentID, before: cursor, limit: limit)
        for run in runs { _ = try await evidence(for: run.id) }
        try checkOpen()
        try await gate.authorizePreparationRead(action, requesterID: reviewerID)
        return runs
    }
    public func progress(for id: RunID) async throws -> RunWorkPlan? {
        _ = try await evidence(for: id)
        return try await coordinator.lifecycle.progress(for: id, in: scope)
    }
    public func history(for id: RunID, after sequence: Int64 = 0, limit: Int = 256) async throws -> [StoredRunEvent] {
        _ = try await evidence(for: id)
        return try await coordinator.lifecycle.history(for: id, in: scope, after: sequence, limit: limit)
    }
    /// Authorized replay/live progress for the native console. Every forwarded event rechecks
    /// the current read policy and exact evidence binding. Overflow requires durable replay.
    public func subscribe(to id: RunID, after sequence: Int64 = 0, capacity: Int = 256) async throws -> RunEventSubscription {
        _ = try await evidence(for: id)
        let source = try await coordinator.lifecycle.subscribe(to: id, in: scope, after: sequence, capacity: capacity)
        let (events, continuation) = AsyncThrowingStream<StoredRunEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
        let forwarding = Task { [weak self] in
            defer { source.cancel() }
            do {
                for try await event in source.events {
                    try Task.checkCancellation()
                    guard let self else { throw RunCoordinatorError.closed }
                    _ = try await self.evidence(for: id)
                    switch continuation.yield(event) {
                    case .enqueued: break
                    case .dropped: throw RunLifecycleError.replayRequired
                    case .terminated: return
                    @unknown default: throw RunLifecycleError.replayRequired
                    }
                }
                continuation.finish()
            } catch { continuation.finish(throwing: error) }
        }
        continuation.onTermination = { _ in forwarding.cancel(); source.cancel() }
        return RunEventSubscription(events: events, finish: {
            forwarding.cancel(); source.cancel(); continuation.finish()
        })
    }
    public func evidenceRecords(for id: RunID, after sequence: Int64 = 0, limit: Int = 100) async throws -> [EvidenceRecord] {
        try await evidence(for: id).records(after: sequence, limit: limit)
    }
    public func inputSnapshot(for id: RunID) async throws -> StoredEvidenceContent {
        let store = try await evidence(for: id)
        guard let binding = try await store.binding(),
              let record = try await store.records(limit: 1).first,
              record.sequence == 1, record.kind == .command, record.source == .runtime,
              record.basis == .observed, record.format == .json,
              let content = try await store.artifact(record.id),
              try ActionFingerprint(bytes: Data(content.text.utf8)) == binding.configurationFingerprint else {
            throw RunCoordinatorError.invalidPreparation
        }
        _ = try await evidence(for: id)
        return content
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
