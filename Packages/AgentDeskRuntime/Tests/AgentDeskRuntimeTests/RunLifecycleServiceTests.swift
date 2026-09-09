import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskPersistence
@testable import AgentDeskRuntime

@MainActor
final class RunLifecycleServiceTests: XCTestCase {
    private struct Fixture: Sendable {
        let root: URL
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let store: OperationalStore
        let service: RunLifecycleService
        var database: URL { root.appendingPathComponent("operations.sqlite") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try OperationalStore(database: root.appendingPathComponent("operations.sqlite"), workspaceID: scope.workspaceID)
            service = try RunLifecycleService(store: store, scope: scope)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    func testDurableLifecycleLiveDeliveryAndReplaySurviveServiceRestart() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope, at: Date(timeIntervalSince1970: 1_000))
        let subscription = try await f.service.subscribe(to: run.id, in: f.scope)
        let states: [RunState] = [.running, .paused, .running, .waitingForApproval, .running, .completed]
        for (index, state) in states.enumerated() {
            _ = try await f.service.transition(run.id, in: f.scope, to: state, expectedSequence: Int64(index + 1),
                at: Date(timeIntervalSince1970: 1_001 + Double(index)))
        }
        var received: [StoredRunEvent] = []
        for try await event in subscription.events { received.append(event) }
        XCTAssertEqual(received.map(\.state), [.queued] + states)
        XCTAssertEqual(received.map(\.sequence), Array(1...7).map(Int64.init))
        let stored = try await f.store.events(for: run.id, in: f.scope)
        XCTAssertEqual(received, stored)
        let restarted = try RunLifecycleService(store: OperationalStore(database: f.database, workspaceID: f.scope.workspaceID), scope: f.scope)
        let replay = try await restarted.subscribe(to: run.id, in: f.scope, after: 5)
        var replayed: [StoredRunEvent] = []
        for try await event in replay.events { replayed.append(event) }
        XCTAssertEqual(replayed, Array(received.suffix(2)))
        let count = await restarted.subscriberCount; XCTAssertEqual(count, 0)
    }

    func testInvalidTransitionsStaleRequestsAndClockRegressionDoNotAppendEvents() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope, at: Date(timeIntervalSince1970: 100))
        do { _ = try await f.service.transition(run.id, in: f.scope, to: .completed, expectedSequence: 1); XCTFail("Queued completion") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .invalidTransition) }
        _ = try await f.service.transition(run.id, in: f.scope, to: .running, expectedSequence: 1, at: Date(timeIntervalSince1970: 110))
        do { _ = try await f.service.transition(run.id, in: f.scope, to: .completed, expectedSequence: 1); XCTFail("Stale update") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .staleSequence) }
        do { _ = try await f.service.transition(run.id, in: f.scope, to: .completed, expectedSequence: 2, at: Date(timeIntervalSince1970: 105)); XCTFail("Backdated event") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .invalidTimestamp) }
        _ = try await f.service.transition(run.id, in: f.scope, to: .completed, expectedSequence: 2, at: Date(timeIntervalSince1970: 120))
        do { _ = try await f.service.transition(run.id, in: f.scope, to: .running, expectedSequence: 3); XCTFail("Terminal reopened") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .invalidTransition) }
        let history = try await f.service.history(for: run.id, in: f.scope)
        XCTAssertEqual(history.map(\.state), [.queued, .running, .completed])
    }

    func testOverflowFailsExplicitlyAndPersistedEventsRemainReplayable() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope)
        let slow = try await f.service.subscribe(to: run.id, in: f.scope, capacity: 1)
        _ = try await f.service.transition(run.id, in: f.scope, to: .running, expectedSequence: 1)
        _ = try await f.service.transition(run.id, in: f.scope, to: .completed, expectedSequence: 2)
        var received: [Int64] = []
        do { for try await event in slow.events { received.append(event.sequence) }; XCTFail("Overflow was silent") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .replayRequired) }
        XCTAssertEqual(received, [1])
        let recovered = try await f.service.subscribe(to: run.id, in: f.scope, after: 1)
        var recovery: [Int64] = []
        for try await event in recovered.events { recovery.append(event.sequence) }
        XCTAssertEqual(recovery, [2, 3])
    }

    func testInvalidCursorAndOversizedReplayRequireExplicitRecovery() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope)
        _ = try await f.service.transition(run.id, in: f.scope, to: .cancelled, expectedSequence: 1)
        for sequence in [Int64(-1), 3] {
            do { _ = try await f.service.subscribe(to: run.id, in: f.scope, after: sequence); XCTFail("Invalid cursor") }
            catch { XCTAssertEqual(error as? RunLifecycleError, .invalidCursor) }
        }
        do { _ = try await f.service.subscribe(to: run.id, in: f.scope, capacity: 1); XCTFail("Replay truncated") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .replayRequired) }
        let page = try await f.service.history(for: run.id, in: f.scope, after: 0, limit: 1)
        XCTAssertEqual(page.map(\.sequence), [1])
        let finished = try await f.service.subscribe(to: run.id, in: f.scope, after: 2)
        var iterator = finished.events.makeAsyncIterator()
        let next = try await iterator.next(); XCTAssertNil(next)
    }

    func testEveryAPIRejectsForeignProjectScopeAndUnknownRun() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let foreign = ProjectScope(workspaceID: f.scope.workspaceID, projectID: ProjectID())
        let run = try await f.service.createRun(in: f.scope)
        do { _ = try await f.service.createRun(in: foreign); XCTFail("Foreign create") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .scopeMismatch) }
        do { _ = try await f.service.run(run.id, in: foreign); XCTFail("Foreign read") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .scopeMismatch) }
        do { _ = try await f.service.subscribe(to: run.id, in: foreign); XCTFail("Foreign subscribe") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .scopeMismatch) }
        do { _ = try await f.service.history(for: run.id, in: foreign); XCTFail("Foreign replay") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .scopeMismatch) }
        do { _ = try await f.service.transition(run.id, in: foreign, to: .running, expectedSequence: 1); XCTFail("Foreign transition") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .scopeMismatch) }
        do { _ = try await f.service.subscribe(to: RunID(), in: f.scope); XCTFail("Missing run") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .missingRun) }
        XCTAssertThrowsError(try RunLifecycleService(store: f.store, scope: ProjectScope(workspaceID: WorkspaceID(), projectID: f.scope.projectID)))
    }

    func testSubscriptionsAreIsolatedByRun() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = try await f.service.createRun(in: f.scope), b = try await f.service.createRun(in: f.scope)
        let first = try await f.service.subscribe(to: a.id, in: f.scope, after: 1)
        let second = try await f.service.subscribe(to: b.id, in: f.scope, after: 1)
        _ = try await f.service.transition(a.id, in: f.scope, to: .cancelled, expectedSequence: 1)
        _ = try await f.service.transition(b.id, in: f.scope, to: .failed, expectedSequence: 1)
        var aEvents: [StoredRunEvent] = [], bEvents: [StoredRunEvent] = []
        for try await event in first.events { aEvents.append(event) }
        for try await event in second.events { bEvents.append(event) }
        XCTAssertEqual(aEvents.map(\.runID), [a.id]); XCTAssertEqual(aEvents.map(\.state), [.cancelled])
        XCTAssertEqual(bEvents.map(\.runID), [b.id]); XCTAssertEqual(bEvents.map(\.state), [.failed])
    }

    func testPersistenceFailureDoesNotEmitGhostStateAndReleasesOperationGate() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope)
        let subscription = try await f.service.subscribe(to: run.id, in: f.scope, after: 1)
        let connection = try SQLiteConnection(database: f.database)
        try connection.execute("CREATE TRIGGER fail_runtime_event BEFORE INSERT ON run_events BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        do { _ = try await f.service.transition(run.id, in: f.scope, to: .running, expectedSequence: 1); XCTFail("Failed commit reported success") }
        catch { XCTAssertTrue(error is OperationalStoreError) }
        try connection.execute("DROP TRIGGER fail_runtime_event")
        _ = try await f.service.transition(run.id, in: f.scope, to: .failed, expectedSequence: 1)
        var events: [StoredRunEvent] = []
        for try await event in subscription.events { events.append(event) }
        XCTAssertEqual(events.map(\.sequence), [2]); XCTAssertEqual(events.map(\.state), [.failed])
    }

    func testConcurrentTransitionsAcceptOneExpectedSequence() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope)
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for _ in 0..<2 {
                group.addTask { (try? await f.service.transition(run.id, in: f.scope, to: .running, expectedSequence: 1)) != nil }
            }
            var count = 0; for await value in group { if value { count += 1 } }; return count
        }
        XCTAssertEqual(count, 1)
        let history = try await f.service.history(for: run.id, in: f.scope)
        XCTAssertEqual(history.map(\.sequence), [1, 2])
    }

    func testExplicitSubscriptionCancellationReleasesObserver() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope)
        let observation = try await f.service.subscribe(to: run.id, in: f.scope, after: 1)
        observation.cancel()
        try await assertObserversReleased(f.service)
        var iterator = observation.events.makeAsyncIterator()
        let next = try await iterator.next(); XCTAssertNil(next)
    }

    func testConsumerTaskCancellationAndCancelledWritesCleanUp() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope)
        let observation = try await f.service.subscribe(to: run.id, in: f.scope, after: 1)
        let consumer = Task { for try await _ in observation.events {} }
        consumer.cancel(); _ = try? await consumer.value
        try await assertObserversReleased(f.service)
        let write = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.service.transition(run.id, in: f.scope, to: .running, expectedSequence: 1)
        }
        do { _ = try await write.value; XCTFail("Cancelled write") }
        catch { XCTAssertTrue(error is CancellationError) }
        let snapshot = try await f.service.run(run.id, in: f.scope); XCTAssertEqual(snapshot?.state, .queued)
        _ = try await f.service.transition(run.id, in: f.scope, to: .cancelled, expectedSequence: 1)
    }

    func testShutdownClosesObserversAndRejectsNewWorkWithoutRewritingHistory() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope)
        let observation = try await f.service.subscribe(to: run.id, in: f.scope, after: 1)
        await f.service.shutdown()
        var iterator = observation.events.makeAsyncIterator()
        do { _ = try await iterator.next(); XCTFail("Shutdown looked like normal completion") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .closed) }
        do { _ = try await f.service.createRun(in: f.scope); XCTFail("Closed service accepted work") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .closed) }
        let state = try await f.store.run(run.id, in: f.scope); XCTAssertEqual(state?.state, .queued)
    }

    private func assertObserversReleased(_ service: RunLifecycleService) async throws {
        for _ in 0..<100 {
            if await service.subscriberCount == 0 { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Observer was retained after termination")
    }

    func testDroppingServiceEndsObserversInsteadOfLeavingThemWaiting() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope)
        var temporary: RunLifecycleService? = try RunLifecycleService(store: f.store, scope: f.scope)
        let observation = try await XCTUnwrap(temporary).subscribe(to: run.id, in: f.scope, after: 1)
        temporary = nil
        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                group.addTask { for try await _ in observation.events {} }
                group.addTask { try await Task.sleep(for: .seconds(2)); throw CancellationError() }
                defer { group.cancelAll() }
                _ = try await group.next()
            }
            XCTFail("Dropped service looked like terminal completion")
        } catch { XCTAssertEqual(error as? RunLifecycleError, .closed) }
    }
}
