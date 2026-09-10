import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskRuntime

actor CoordinatorFakeProvider: ExecutionProvider {
    enum Mode: Sendable { case success, quiet, lateEvent, lateError, earlyEOF, wrongScope, overflow, incompleteActivity, schemaFailure }
    nonisolated let resource: ExecutionResource
    nonisolated let cancellations = Mutex(0)
    let mode: Mode
    var requests: [ExecutionRequest] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(resource: ExecutionResource, mode: Mode) { self.resource = resource; self.mode = mode }
    func waitForStart() async { if requests.isEmpty { await withCheckedContinuation { waiters.append($0) } } }
    func start(_ request: ExecutionRequest) async throws -> ProviderExecution {
        requests.append(request)
        for waiter in waiters { waiter.resume() }; waiters.removeAll()
        let (stream, continuation) = AsyncThrowingStream<ExecutionProviderEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(16))
        var sequence: Int64 = 0
        func emit(_ payload: ExecutionProviderEvent.Payload) {
            sequence += 1
            let identity = mode == .wrongScope ? ExecutionIdentity(scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()),
                runID: request.identity.runID, agentID: request.identity.agentID, environmentID: request.identity.environmentID) : request.identity
            continuation.yield(.init(identity: identity, sequence: sequence, payload: payload))
        }
        emit(.started)
        if mode != .quiet {
            emit(.activity(id: "synthetic", kind: .command, completed: false))
            if mode != .incompleteActivity { emit(.activity(id: "synthetic", kind: .command, completed: true)) }
            let text = mode == .overflow ? String(repeating: "x", count: request.maximumOutputBytes + 1)
                : "password=fixture-provider-secret\nObserved synthetic file."
            emit(.message(id: "result", text: text))
            if mode != .earlyEOF { emit(.completed(text: text)) }
            if mode == .lateEvent { emit(.message(id: "late", text: "Unverified extra result")) }
            if mode == .lateError { continuation.finish(throwing: ExecutionProviderError.processFailed) }
            else { continuation.finish() }
        }
        return ProviderExecution(events: stream) { [self] in
            cancellations.withLock { $0 += 1 }
            continuation.finish(throwing: CancellationError())
        }
    }
}

@MainActor
final class RunCoordinatorTests: XCTestCase {
    struct Fixture: Sendable {
        let root: URL
        let scope: ProjectScope
        let configuration: EffectiveExecutionConfiguration
        let instructions: ComposedInstructions
        let requester: PolicyAuthority
        let reviewer: PolicyAuthority
        let gate: PolicyGate
        let approvals: ApprovalStore
        let provider: CoordinatorFakeProvider
        let coordinator: RunCoordinator
        var database: URL { root.appendingPathComponent("operations.sqlite") }
        static func make(mode: CoordinatorFakeProvider.Mode = .success, disposition: PolicyDisposition = .allow,
                         timeout: Int = 30, schema: OutputSchema? = nil, maximumSteps: Int = 30) async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic")
            let project = try await catalog.createProject(in: workspace.id, name: "Synthetic project"), scope = project.scope
            let agents = try await catalog.agentStore(in: scope)
            var draft = AgentTemplate.general.draft; draft.profile.maximumSteps = maximumSteps
            let agent = try await agents.create(draft, in: scope)
            let configurations = try await catalog.executionConfigurationStore(in: scope)
            let rules = [PolicyRule(.readEvidence, .allow), PolicyRule(.runReadOnlyAgent, disposition)]
            let envID = EnvironmentID()
            let environment = ProjectEnvironment(id: envID, scope: scope, name: "Test", kind: .test,
                policy: try PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: envID, rules: rules))
            _ = try await configurations.save(.init(policy: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules)),
                at: .workspace, in: scope, expectedRevision: nil)
            _ = try await configurations.save(.init(settings: .init(timeoutSeconds: timeout, maximumOutputBytes: 1_024, outputSchema: schema),
                environments: [environment], defaultEnvironmentID: envID,
                policy: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules)),
                at: .project, in: scope, expectedRevision: nil)
            let configuration = try await configurations.preview(for: agent, in: scope)
            let instructionStore = try await catalog.instructionStore(in: scope)
            let instructions = try await instructionStore.preview(for: agent, in: scope)
            let requester = try PolicyAuthority(id: UUID(), kind: .agent(agent.id), scopes: [scope], environments: [envID],
                operations: [.readEvidence, .runReadOnlyAgent], expiresAt: Date().addingTimeInterval(600))
            let reviewer = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [envID],
                operations: [.readEvidence, .runReadOnlyAgent], canApprove: true, expiresAt: Date().addingTimeInterval(600))
            let approvals = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: envID)
            let gate = try PolicyGate(policy: configuration.policy, authorities: [requester, reviewer], store: approvals)
            let provider = CoordinatorFakeProvider(resource: try .directory(in: scope, device: 1, inode: 2), mode: mode)
            let coordinator = try RunCoordinator(database: root.appendingPathComponent("operations.sqlite"), scope: scope,
                environmentID: envID, gate: gate, provider: provider)
            _ = try await coordinator.recoverInterruptedRuns()
            return Self(root: root, scope: scope, configuration: configuration, instructions: instructions, requester: requester,
                reviewer: reviewer, gate: gate, approvals: approvals, provider: provider, coordinator: coordinator)
        }
        func prepare() async throws -> PreparedRun {
            try await coordinator.prepare(instructions: instructions, configuration: configuration,
                task: "Inspect the synthetic project.\npassword=fixture-input-secret", requesterID: requester.id,
                redactor: { try ContentRedactor(context: $0) })
        }
        func evidence(_ prepared: PreparedRun) throws -> EvidenceStore {
            try EvidenceStore(database: database, context: RedactionContext(scope: scope, environmentID: configuration.environment.id,
                runID: prepared.runID), agentID: configuration.agentID)
        }
        func remove() async { await coordinator.shutdown(); try? FileManager.default.removeItem(at: root) }
    }

    func testRunPersistsSanitizedInputsProgressAndFinalEvidenceAcrossReopen() async throws {
        let f = try await Fixture.make(maximumSteps: 1_000)
        let prepared = try await f.prepare()
        XCTAssertEqual(prepared.maximumActivities, 128)
        let execution = try await f.coordinator.start(prepared.token), outcome = await execution.result()
        XCTAssertEqual(outcome.state, .completed); XCTAssertNil(outcome.failure)
        let requests = await f.provider.requests
        XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests[0].maximumActivities, 128)
        XCTAssertFalse(requests[0].task.contains("fixture-input-secret"))
        let progress = try await f.coordinator.lifecycle.progress(for: prepared.runID, in: f.scope)
        XCTAssertNil(progress?.overallProgress); XCTAssertEqual(progress?.items.count, 4)
        XCTAssertTrue(progress?.items.allSatisfy { $0.state == .completed } == true)
        let evidence = try f.evidence(prepared), records = try await evidence.records(limit: 256)
        XCTAssertEqual(records.last?.id, outcome.finalArtifactID)
        let output = try await evidence.artifact(XCTUnwrap(outcome.finalArtifactID))
        XCTAssertTrue(output?.text.contains("Observed synthetic file.") == true)
        XCTAssertFalse(output?.text.contains("fixture-provider-secret") == true)
        for record in records {
            let text: String?
            if record.kind == .trace { text = try await evidence.trace(record.id)?.content.text }
            else { text = try await evidence.artifact(record.id)?.text }
            XCTAssertFalse(text?.contains("fixture-input-secret") == true)
            XCTAssertFalse(text?.contains("fixture-provider-secret") == true)
        }
        let reopened = try OperationalStore(database: f.database, workspaceID: f.scope.workspaceID)
        let stored = try await reopened.run(prepared.runID, in: f.scope), binding = try await reopened.evidenceBinding(for: prepared.runID, in: f.scope)
        XCTAssertEqual(stored?.state, .completed); XCTAssertEqual(binding?.context.runID, prepared.runID)
        await f.remove()
    }

    func testApprovalWaitsBeforeProviderLaunchAndCannotReplay() async throws {
        let f = try await Fixture.make(disposition: .approval), prepared = try await f.prepare()
        let before = try await f.coordinator.lifecycle.run(prepared.runID, in: f.scope)
        XCTAssertEqual(before?.state, .waitingForApproval)
        do { _ = try await f.coordinator.start(prepared.token); XCTFail("Unapproved run started") } catch { XCTAssertEqual(error as? AuthorizationError, .approvalRequired) }
        let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty)
        let approval = try XCTUnwrap(prepared.approval)
        _ = try await f.gate.review(approval.id, expectedAction: prepared.action, requesterID: f.requester.id,
            reviewerID: f.reviewer.id, approve: true, expectedSequence: approval.sequence)
        let execution = try await f.coordinator.start(prepared.token), outcome = await execution.result()
        XCTAssertEqual(outcome.state, .completed)
        let consumed = try await f.approvals.approval(approval.id); XCTAssertEqual(consumed?.state, .consumed)
        do { _ = try await f.coordinator.start(prepared.token); XCTFail("Prepared token replayed") } catch {}
        await f.remove()
    }

    func testDeniedAndForeignPreparationCreateNoRun() async throws {
        let f = try await Fixture.make(disposition: .deny)
        do {
            _ = try await f.coordinator.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect",
                requesterID: f.requester.id, redactor: { context in
                    XCTFail("Denied requester resolved redaction secrets"); return try ContentRedactor(context: context)
                })
            XCTFail("Denied preparation")
        } catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        let other = try await Fixture.make()
        do {
            _ = try await other.coordinator.prepare(instructions: f.instructions, configuration: other.configuration, task: "Synthetic",
                requesterID: other.requester.id, redactor: { try ContentRedactor(context: $0) })
            XCTFail("Foreign instructions accepted")
        } catch { XCTAssertEqual(error as? RunCoordinatorError, .invalidPreparation) }
        let store = try OperationalStore(database: f.database, workspaceID: f.scope.workspaceID)
        let runs = try await store.runs(in: f.scope); XCTAssertTrue(runs.isEmpty)
        await f.remove(); await other.remove()
    }

    func testInvalidProviderStreamsNeverPublishAConfirmedFinalOutput() async throws {
        for mode: CoordinatorFakeProvider.Mode in [.lateEvent, .lateError, .earlyEOF, .wrongScope, .overflow, .incompleteActivity, .schemaFailure] {
            let f = try await Fixture.make(mode: mode, schema: mode == .schemaFailure ? .object(["ok": .boolean]) : nil)
            let prepared = try await f.prepare(), execution = try await f.coordinator.start(prepared.token), outcome = await execution.result()
            XCTAssertEqual(outcome.state, .failed); XCTAssertNotNil(outcome.failure); XCTAssertNil(outcome.finalArtifactID)
            XCTAssertEqual(f.provider.cancellations.withLock { $0 }, 1)
            await f.remove()
        }
    }

    func testQuietProviderCancellationTimeoutAndRevocationStopAndPersist() async throws {
        for reason in ["cancel", "timeout", "revoke", "policy"] {
            let f = try await Fixture.make(mode: .quiet, timeout: reason == "timeout" ? 1 : 30)
            let prepared = try await f.prepare(), execution = try await f.coordinator.start(prepared.token)
            await f.provider.waitForStart()
            switch reason {
            case "cancel": execution.cancel()
            case "revoke": await f.gate.removeAuthority(f.requester.id)
            case "policy":
                let prior = f.configuration.policy
                try await f.gate.installPolicy(PolicySnapshot(workspace: prior.workspace, project: prior.project,
                    environment: prior.environment, environmentKind: prior.environmentKind, workspaceLocked: true))
            default: break
            }
            let outcome = await execution.result()
            XCTAssertEqual(outcome.state, reason == "cancel" ? .cancelled : .failed, reason)
            XCTAssertEqual(outcome.failure, reason == "cancel" ? .cancelled : reason == "timeout" ? .timedOut : .unauthorized, reason)
            XCTAssertEqual(f.provider.cancellations.withLock { $0 }, 1)
            let run = try await f.coordinator.lifecycle.run(prepared.runID, in: f.scope)
            XCTAssertEqual(run?.state, outcome.state)
            await f.remove()
        }
    }

    func testProjectLeaseExcludesAnotherOwnerUntilShutdown() async throws {
        let f = try await Fixture.make()
        XCTAssertThrowsError(try RunCoordinator(database: f.database, scope: f.scope, environmentID: EnvironmentID(), gate: f.gate, provider: f.provider)) {
            XCTAssertEqual($0 as? RunCoordinatorError, .busy)
        }
        await f.coordinator.shutdown()
        let reopened = try RunCoordinator(database: f.database, scope: f.scope, environmentID: f.configuration.environment.id, gate: f.gate, provider: f.provider)
        let recovered = try await reopened.recoverInterruptedRuns(); XCTAssertEqual(recovered, 0)
        await reopened.shutdown(); await f.remove()
    }

    func testRecoveryPagesAllUnfinishedRunsAndPreservesOtherProjectAndTerminalHistory() async throws {
        let f = try await Fixture.make()
        let store = try OperationalStore(database: f.database, workspaceID: f.scope.workspaceID)
        let other = ProjectScope(workspaceID: f.scope.workspaceID, projectID: ProjectID())
        let foreign = try await store.createRun(in: other)
        let completed = try await store.createRun(in: f.scope)
        _ = try await store.recordState(.completed, for: completed.id, in: f.scope, expectedSequence: 1)
        for index in 0..<260 {
            let run = try await store.createRun(in: f.scope)
            if index % 3 == 0 { _ = try await store.recordState(.running, for: run.id, in: f.scope, expectedSequence: 1) }
            if index % 3 == 1 { _ = try await store.recordState(.waitingForApproval, for: run.id, in: f.scope, expectedSequence: 1) }
        }
        let recovered = try await f.coordinator.recoverInterruptedRuns(); XCTAssertEqual(recovered, 260)
        let unfinished = try await store.unfinishedRuns(in: f.scope); XCTAssertTrue(unfinished.isEmpty)
        let foreignRun = try await store.run(foreign.id, in: other), terminal = try await store.run(completed.id, in: f.scope)
        XCTAssertEqual(foreignRun?.state, .queued); XCTAssertEqual(terminal?.state, .completed)
        await f.remove()
    }

    func testUnavailablePersistenceReportsUnconfirmedTerminalState() async throws {
        let f = try await Fixture.make(mode: .quiet), prepared = try await f.prepare()
        let execution = try await f.coordinator.start(prepared.token)
        await f.provider.waitForStart()
        await f.coordinator.lifecycle.shutdown()
        execution.cancel()
        let outcome = await execution.result()
        XCTAssertNil(outcome.state); XCTAssertEqual(outcome.failure, .persistenceUnavailable)
        await f.remove()
    }
}
