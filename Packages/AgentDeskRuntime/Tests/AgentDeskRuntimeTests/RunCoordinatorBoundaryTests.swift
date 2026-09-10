import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskRuntime

private actor PreparationBarrier {
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var release: CheckedContinuation<Void, Never>?
    func hold() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }; enteredWaiters.removeAll()
        await withCheckedContinuation { release = $0 }
    }
    func waitForEntry() async { if !entered { await withCheckedContinuation { enteredWaiters.append($0) } } }
    func resume() { release?.resume(); release = nil }
}
private actor CoordinatorFakeRepository: RunRepositoryCapturing {
    nonisolated let context: RedactionContext
    nonisolated let resource: ExecutionResource
    let redactor: ContentRedactor
    let failFinal: Bool
    init(context: RedactionContext, resource: ExecutionResource, redactor: ContentRedactor, failFinal: Bool = false) {
        self.context = context; self.resource = resource; self.redactor = redactor; self.failFinal = failFinal
    }
    func captureBaseline() throws -> RepositoryEvidence { try capture("baseline") }
    func captureChanges() throws -> RepositoryEvidence {
        guard !failFinal else { throw RunCoordinatorError.repositoryFailed }
        return try capture("final")
    }
    private func capture(_ phase: String) throws -> RepositoryEvidence {
        RepositoryEvidence(snapshot: try redactor.redactJSON("{\"phase\":\"\(phase)\"}", in: context),
            diff: try redactor.redactText("Synthetic comparison \(phase)", in: context))
    }
}

@MainActor
final class RunCoordinatorBoundaryTests: XCTestCase {
    func testForeignPhysicalRepositoryIsRejectedAndFinalCaptureFailureDoesNotSucceed() async throws {
        for mode in ["foreign", "failed", "valid"] {
            let f = try await RunCoordinatorTests.Fixture.make(), resource = f.provider.resource
            do {
                let prepared = try await f.coordinator.prepare(instructions: f.instructions, configuration: f.configuration,
                    task: "Inspect synthetic data", requesterID: f.requester.id, redactor: { try ContentRedactor(context: $0) },
                    repository: { context, redactor in
                        CoordinatorFakeRepository(context: context,
                            resource: try mode == "foreign" ? .directory(in: context.scope, device: 1, inode: 99) : resource,
                            redactor: redactor, failFinal: mode == "failed")
                    })
                XCTAssertNotEqual(mode, "foreign")
                let execution = try await f.coordinator.start(prepared.token), outcome = await execution.result()
                XCTAssertEqual(outcome.state, mode == "failed" ? .failed : .completed)
                if mode == "failed" { XCTAssertEqual(outcome.failure, .repositoryFailed); XCTAssertNil(outcome.finalArtifactID) }
                let records = try await f.evidence(prepared).records()
                XCTAssertEqual(records.filter { $0.kind == .repositorySnapshot }.count, mode == "failed" ? 1 : 2)
            } catch { XCTAssertEqual(mode, "foreign"); XCTAssertEqual(error as? RunCoordinatorError, .invalidPreparation) }
            await f.remove()
        }
    }
    func testDeclinedApprovalStalePolicyAndDiscardDoNotLaunch() async throws {
        for mode in ["decline", "policy", "discard"] {
            let f = try await RunCoordinatorTests.Fixture.make(disposition: .approval), prepared = try await f.prepare()
            if mode == "decline" {
                let approval = try XCTUnwrap(prepared.approval)
                _ = try await f.gate.review(approval.id, expectedAction: prepared.action, requesterID: f.requester.id,
                    reviewerID: f.reviewer.id, approve: false, expectedSequence: approval.sequence)
            } else if mode == "policy" {
                let old = f.configuration.policy
                try await f.gate.installPolicy(PolicySnapshot(workspace: old.workspace, project: old.project,
                    environment: old.environment, environmentKind: old.environmentKind, workspaceLocked: true))
            } else {
                let discarded = try await f.coordinator.discard(prepared.token)
                XCTAssertEqual(discarded.state, .cancelled)
            }
            do { _ = try await f.coordinator.start(prepared.token); XCTFail("Unapproved/discarded token launched") } catch {}
            let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty)
            await f.remove()
        }
    }
    func testConcurrentShutdownWaitsForPreparationAndReleasesLeaseOnlyAfterCleanup() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(), barrier = PreparationBarrier()
        let preparation = Task {
            try await f.coordinator.prepare(instructions: f.instructions, configuration: f.configuration,
                task: "Inspect", requesterID: f.requester.id, redactor: { context in
                    await barrier.hold(); return try ContentRedactor(context: context)
                })
        }
        await barrier.waitForEntry()
        let first = Task { await f.coordinator.shutdown() }
        let second = Task { await f.coordinator.shutdown() }
        // The held preparation still owns the project; shutdown cannot release its lease early.
        XCTAssertThrowsError(try RunCoordinator(database: f.database, scope: f.scope,
            environmentID: f.configuration.environment.id, gate: f.gate, provider: f.provider))
        await barrier.resume()
        _ = try? await preparation.value
        await first.value; await second.value
        let reopened = try RunCoordinator(database: f.database, scope: f.scope,
            environmentID: f.configuration.environment.id, gate: f.gate, provider: f.provider)
        let recovered = try await reopened.recoverInterruptedRuns(); XCTAssertEqual(recovered, 0)
        await reopened.shutdown(); await f.remove()
    }
    func testShutdownCancelsActiveRunBeforeReleasingProject() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(mode: .quiet), prepared = try await f.prepare()
        let execution = try await f.coordinator.start(prepared.token)
        await f.provider.waitForStart()
        async let first: Void = f.coordinator.shutdown()
        async let second: Void = f.coordinator.shutdown()
        _ = await (first, second)
        let outcome = await execution.result(); XCTAssertEqual(outcome.state, .cancelled)
        XCTAssertEqual(f.provider.cancellations.withLock { $0 }, 1)
        await f.remove()
    }
    func testLeaseRejectsSymlinksHardlinksAndReplacedLockAndIsolatesProjects() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let name = ".run-owner-\(scope.workspaceID.rawValue).\(scope.projectID.rawValue).lock", lock = root.appendingPathComponent(name)
        let target = root.appendingPathComponent("synthetic")
        try Data().write(to: target); XCTAssertEqual(chmod(target.path, 0o600), 0)
        try FileManager.default.createSymbolicLink(at: lock, withDestinationURL: target)
        XCTAssertThrowsError(try RunCoordinatorLease(container: root, scope: scope))
        try FileManager.default.removeItem(at: lock)
        XCTAssertEqual(link(target.path, lock.path), 0)
        XCTAssertThrowsError(try RunCoordinatorLease(container: root, scope: scope))
        try FileManager.default.removeItem(at: lock)
        let lease = try RunCoordinatorLease(container: root, scope: scope)
        let other = try RunCoordinatorLease(container: root, scope: ProjectScope(workspaceID: scope.workspaceID, projectID: ProjectID()))
        try other.validate(); try lease.validate()
        try FileManager.default.removeItem(at: lock)
        try Data().write(to: lock); XCTAssertEqual(chmod(lock.path, 0o600), 0)
        XCTAssertThrowsError(try lease.validate())
    }
    func testEventValidatorRejectsSequenceDuplicateActivitiesAndUnobservedCompletion() throws {
        let identity = ExecutionIdentity(scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()),
            runID: RunID(), agentID: AgentID(), environmentID: EnvironmentID())
        let request = ExecutionRequest(identity: identity, instructions: "Inspect", task: "Synthetic", model: nil,
            timeout: .seconds(30), maximumActivities: 1)
        let cases: [[ExecutionProviderEvent.Payload]] = [
            [.started, .started], [.message(id: "x", text: "x")], [.started, .completed(text: "unobserved")],
            [.started, .activity(id: "x", kind: .fileChange, completed: false)],
            [.started, .activity(id: "x", kind: .command, completed: true)],
            [.started, .activity(id: "x", kind: .command, completed: false), .activity(id: "x", kind: .command, completed: false)],
            [.started, .activity(id: "x", kind: .command, completed: false), .activity(id: "x", kind: .planning, completed: true)],
            [.started, .activity(id: "x", kind: .command, completed: false), .activity(id: "y", kind: .command, completed: false)],
            [.started, .message(id: "x", text: "x"), .message(id: "x", text: "x")]
        ]
        for payloads in cases {
            var validator = RunEventValidator(request: request)
            XCTAssertThrowsError(try payloads.enumerated().forEach { index, payload in
                _ = try validator.accept(.init(identity: identity, sequence: Int64(index + 1), payload: payload))
            })
        }
        var validator = RunEventValidator(request: request)
        XCTAssertThrowsError(try validator.accept(.init(identity: identity, sequence: 2, payload: .started)))
    }
}
