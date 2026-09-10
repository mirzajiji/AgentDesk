#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class NativeRunServiceTests: XCTestCase {
    func testNativeObservationCancellationDoesNotCancelExecutionAndOverflowRequiresReplay() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(mode: .quiet)
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect")
        let execution = try await service.start(prepared)
        await f.provider.waitForStart()
        let stored = try await service.run(prepared.runID), current = try XCTUnwrap(stored)
        let cancelled = try await service.subscribe(to: prepared.runID, after: current.sequence)
        cancelled.cancel()
        var iterator = cancelled.events.makeAsyncIterator()
        let next = try await iterator.next(); XCTAssertNil(next)
        let stillRunning = try await service.run(prepared.runID); XCTAssertFalse(stillRunning?.state.isTerminal == true)
        let slow = try await service.subscribe(to: prepared.runID, after: current.sequence, capacity: 1)
        execution.cancel()
        let outcome = await execution.result(); XCTAssertEqual(outcome.state, .cancelled)
        let history = try await service.history(for: prepared.runID, after: current.sequence)
        XCTAssertEqual(history.last?.state, .cancelled)
        // Scheduling may let the consumer catch up. It must receive everything or explicit replayRequired.
        do {
            var observed: [StoredRunEvent] = []
            for try await event in slow.events { observed.append(event) }
            XCTAssertEqual(observed, history, "Backpressure must not silently discard updates")
        } catch { XCTAssertEqual(error as? RunLifecycleError, .replayRequired) }
        await service.shutdown()
        do { _ = try await service.subscribe(to: prepared.runID); XCTFail("Closed service observed") }
        catch { XCTAssertEqual(error as? RunCoordinatorError, .closed) }
        await f.remove()
    }
    func testAuthorizedNativeSubscriptionReplaysAndFinishesWithDurableTerminalState() async throws {
        let f = try await RunCoordinatorTests.Fixture.make()
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect")
        let subscription = try await service.subscribe(to: prepared.runID)
        let collecting = Task { () throws -> [StoredRunEvent] in
            var events: [StoredRunEvent] = []
            for try await event in subscription.events { events.append(event) }
            return events
        }
        let execution = try await service.start(prepared)
        let outcome = await execution.result()
        let events = try await collecting.value
        let history = try await service.history(for: prepared.runID)
        XCTAssertEqual(outcome.state, .completed)
        XCTAssertEqual(events, history)
        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertTrue(events.allSatisfy { $0.scope == f.scope && $0.runID == prepared.runID })
        let ended = try await service.subscribe(to: prepared.runID, after: XCTUnwrap(events.last?.sequence))
        var iterator = ended.events.makeAsyncIterator()
        let next = try await iterator.next(); XCTAssertNil(next)
        do { _ = try await service.subscribe(to: prepared.runID, capacity: 1); XCTFail("Large replay silently truncated") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .replayRequired) }
        await service.shutdown(); await f.remove()
    }

    func testNativeSubscriptionRejectsUnboundRunsAndStopsOnReadRevocation() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(mode: .quiet)
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        do { _ = try await service.subscribe(to: RunID()); XCTFail("Unbound run observed") } catch {}
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect")
        let execution = try await service.start(prepared)
        await f.provider.waitForStart()
        let stored = try await service.run(prepared.runID)
        let current = try XCTUnwrap(stored)
        let subscription = try await service.subscribe(to: prepared.runID, after: current.sequence)
        let prior = f.configuration.policy
        let denied = try PolicyDocument(level: .environment, workspaceID: f.scope.workspaceID,
            projectID: f.scope.projectID, environmentID: f.configuration.environment.id, rules: [])
        try await service.installPolicy(PolicySnapshot(workspace: prior.workspace, project: prior.project,
            environment: denied, environmentKind: prior.environmentKind))
        let outcome = await execution.result(); XCTAssertEqual(outcome.failure, .unauthorized)
        do { for try await _ in subscription.events {}; XCTFail("Read revocation was hidden") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        do { _ = try await service.subscribe(to: prepared.runID); XCTFail("Denied subscription opened") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        await service.shutdown(); await f.remove()
    }
    func testStaleDisplayedContextCannotCreateRunAndRefreshedContextRequiresReview() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(disposition: .approval)
        await f.coordinator.shutdown()
        let catalog = try WorkspaceCatalog(container: f.root)
        let setup = ProjectExecutionSetupService(catalog: catalog, scope: f.scope)
        let initial = try await setup.preview(agentID: f.configuration.agentID)
        let service = try await NativeRunService.open(database: f.database, directory: f.root, configuration: initial.configuration,
            captureRepository: false, provider: f.provider)
        let document = InstructionDocument(title: "Current context", text: "Use the revised synthetic test context.")
        _ = try await catalog.instructionStore(in: f.scope).save(.init(documents: [document], roots: [document.id]),
            at: .project, in: f.scope, expectedRevision: nil)
        do { _ = try await service.prepare(context: initial, setup: setup, task: "Inspect"); XCTFail("Stale preview created a run") }
        catch { XCTAssertEqual(error as? ExecutionSetupError, .staleContext) }
        let storage = try OperationalStore(database: f.database, workspaceID: f.scope.workspaceID)
        let empty = try await storage.runs(in: f.scope); XCTAssertTrue(empty.isEmpty)
        let none = await f.provider.requests; XCTAssertTrue(none.isEmpty)
        let current = try await setup.preview(agentID: f.configuration.agentID)
        let prepared = try await service.prepare(context: current, setup: setup, task: "Inspect")
        let waiting = try await service.run(prepared.runID); XCTAssertEqual(waiting?.state, .waitingForApproval)
        do { _ = try await service.start(prepared); XCTFail("Review bypassed") }
        catch { XCTAssertEqual(error as? AuthorizationError, .approvalRequired) }
        _ = try await service.review(prepared, approve: true, expectedSequence: XCTUnwrap(prepared.approval?.sequence))
        let execution = try await service.start(prepared), result = await execution.result()
        XCTAssertEqual(result.state, .completed)
        let requests = await f.provider.requests
        XCTAssertEqual(requests.count, 1); XCTAssertTrue(requests.first?.instructions.contains(document.text) == true)
        await service.shutdown(); await f.remove()
    }
    func testLocalReviewDispatchAndScopedEvidenceFlow() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(disposition: .approval)
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root, configuration: f.configuration,
            captureRepository: false, provider: f.provider)
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect synthetic content")
        let before = try await service.run(prepared.runID); XCTAssertEqual(before?.state, .waitingForApproval)
        do { _ = try await service.start(prepared); XCTFail("Native service skipped review") } catch {}
        let approval = try XCTUnwrap(prepared.approval)
        let reviewed = try await service.review(prepared, approve: true, expectedSequence: approval.sequence)
        XCTAssertEqual(reviewed.state, .approved)
        let execution = try await service.start(prepared), outcome = await execution.result()
        XCTAssertEqual(outcome.state, .completed)
        let records = try await service.evidenceRecords(for: prepared.runID), history = try await service.history(for: prepared.runID)
        let listed = try await service.runs()
        XCTAssertEqual(listed.map(\.id), [prepared.runID])
        let older = try await service.runs(before: prepared.runID)
        XCTAssertTrue(older.isEmpty)
        XCTAssertFalse(records.isEmpty); XCTAssertEqual(history.last?.state, .completed)
        let output = try await service.artifact(XCTUnwrap(outcome.finalArtifactID), for: prepared.runID)
        XCTAssertFalse(output?.text.contains("fixture-provider-secret") == true)
        do { _ = try await service.evidenceRecords(for: RunID()); XCTFail("Unbound run read") } catch {}
        // Same project but a different environment/agent cannot disclose this run through a fresh service.
        let other = try await RunCoordinatorTests.Fixture.make()
        await other.coordinator.shutdown()
        let foreign = try await NativeRunService.open(database: f.database, directory: f.root, configuration: other.configuration,
            captureRepository: false, provider: other.provider)
        do { _ = try await foreign.artifact(XCTUnwrap(outcome.finalArtifactID), for: prepared.runID); XCTFail("Foreign artifact disclosed") } catch {}
        do { _ = try await foreign.subscribe(to: prepared.runID); XCTFail("Foreign run observed") } catch {}
        let foreignList = try await foreign.runs(); XCTAssertTrue(foreignList.isEmpty)
        await foreign.shutdown(); await other.remove()
        await service.shutdown(); await f.remove()
    }
    func testInstalledPolicyStopsActiveNativeRunAndReadDenialIsEnforced() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(mode: .quiet)
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root, configuration: f.configuration,
            captureRepository: false, provider: f.provider)
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect")
        let execution = try await service.start(prepared)
        await f.provider.waitForStart()
        let prior = f.configuration.policy
        let denied = try PolicyDocument(level: .environment, workspaceID: f.scope.workspaceID, projectID: f.scope.projectID,
            environmentID: f.configuration.environment.id, rules: [])
        try await service.installPolicy(PolicySnapshot(workspace: prior.workspace, project: prior.project,
            environment: denied, environmentKind: prior.environmentKind))
        let outcome = await execution.result(); XCTAssertEqual(outcome.state, .failed); XCTAssertEqual(outcome.failure, .unauthorized)
        do { _ = try await service.progress(for: prepared.runID); XCTFail("Denied progress read") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        do { _ = try await service.runs(); XCTFail("Denied history list") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        await service.shutdown(); await f.remove()
    }
    func testClosedServiceRejectsPreparationAndInvalidRepositoryStopsBeforeExecution() async throws {
        let f = try await RunCoordinatorTests.Fixture.make()
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root, configuration: f.configuration,
            captureRepository: true, provider: f.provider)
        do {
            _ = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect")
            XCTFail("Invalid repository accepted")
        } catch {}
        let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty)
        await service.shutdown()
        do { _ = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect"); XCTFail("Closed service") }
        catch { XCTAssertEqual(error as? RunCoordinatorError, .closed) }
        await f.remove()
    }
}
#endif
