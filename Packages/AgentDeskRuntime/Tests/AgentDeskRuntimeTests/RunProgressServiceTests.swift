import AgentDeskCore
import AgentDeskPersistence
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class RunProgressServiceTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let service: RunLifecycleService
        var database: URL { root.appendingPathComponent("operations.sqlite") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let store = try OperationalStore(database: root.appendingPathComponent("operations.sqlite"), workspaceID: scope.workspaceID)
            service = try RunLifecycleService(store: store, scope: scope)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    func testLiveProgressUsesOneDurableSequenceAndReplaysThroughTerminalSnapshot() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope)
        let stage = WorkItemDefinition(kind: .stage, title: "Validate synthetic cases")
        let step = WorkItemDefinition(kind: .step, parentStageID: stage.id, title: "Execute known cases")
        let plan = try RunWorkPlan(scope: f.scope, runID: run.id, mode: .fixedStages, definitions: [stage, step])
        let subscription = try await f.service.subscribe(to: run.id, in: f.scope)
        _ = try await f.service.configureProgress(plan, in: f.scope, expectedSequence: 1)
        _ = try await f.service.transition(run.id, in: f.scope, to: .running, expectedSequence: 2)
        let changes: [WorkPlanChange] = [.transition(stage.id, to: .running), .transition(step.id, to: .running),
            .measure(step.id, completed: 1, total: 2), .measure(step.id, completed: 2, total: 2),
            .transition(step.id, to: .completed), .transition(stage.id, to: .completed)]
        for (index, change) in changes.enumerated() {
            _ = try await f.service.changeProgress(change, for: run.id, in: f.scope, expectedSequence: Int64(index + 3))
        }
        _ = try await f.service.transition(run.id, in: f.scope, to: .completed, expectedSequence: 9)
        var received: [StoredRunEvent] = []
        for try await event in subscription.events { received.append(event) }
        XCTAssertEqual(received.map(\.sequence), Array(1...10).map(Int64.init))
        XCTAssertEqual(received.filter { $0.kind == .progress }.count, 7)
        XCTAssertEqual(received[5].progress?.items[1].progress?.fractionCompleted, 0.5)
        XCTAssertEqual(received[5].progress?.overallProgress?.fractionCompleted, 0)
        XCTAssertEqual(received.last?.progress?.overallProgress?.fractionCompleted, 1)
        let restarted = try RunLifecycleService(store: OperationalStore(database: f.database, workspaceID: f.scope.workspaceID), scope: f.scope)
        let stored = try await restarted.history(for: run.id, in: f.scope)
        XCTAssertEqual(received, stored)
        let snapshot = try await restarted.progress(for: run.id, in: f.scope)
        XCTAssertEqual(snapshot, received.last?.progress)
        let replay = try await restarted.subscribe(to: run.id, in: f.scope, after: 5)
        var replayed: [StoredRunEvent] = []
        for try await event in replay.events { replayed.append(event) }
        XCTAssertEqual(replayed, Array(received.suffix(5)))
    }

    func testPausedRunRejectsUpdatesAndCancellationPublishesFinalOpenEndedProgress() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope)
        let stage = WorkItemDefinition(kind: .stage, title: "Investigate")
        _ = try await f.service.configureProgress(RunWorkPlan(scope: f.scope, runID: run.id, mode: .openEnded, definitions: [stage]), in: f.scope, expectedSequence: 1)
        _ = try await f.service.transition(run.id, in: f.scope, to: .running, expectedSequence: 2)
        _ = try await f.service.changeProgress(.transition(stage.id, to: .running), for: run.id, in: f.scope, expectedSequence: 3)
        _ = try await f.service.transition(run.id, in: f.scope, to: .paused, expectedSequence: 4)
        do { _ = try await f.service.changeProgress(.transition(stage.id, to: .completed), for: run.id, in: f.scope, expectedSequence: 5); XCTFail("Paused progress advanced") }
        catch { XCTAssertEqual(error as? WorkPlanError, .invalidTransition) }
        let subscription = try await f.service.subscribe(to: run.id, in: f.scope, after: 5)
        _ = try await f.service.transition(run.id, in: f.scope, to: .cancelled, expectedSequence: 5)
        var events: [StoredRunEvent] = []
        for try await event in subscription.events { events.append(event) }
        XCTAssertEqual(events.map(\.sequence), [6])
        XCTAssertEqual(events.first?.progress?.items[0].state, .cancelled)
        XCTAssertNil(events.first?.progress?.overallProgress)
    }

    func testProgressAPIsRejectForeignScopesAndShutdownWithoutChangingHistory() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.service.createRun(in: f.scope)
        let plan = try RunWorkPlan(scope: f.scope, runID: run.id, mode: .openEnded, definitions: [])
        let foreign = ProjectScope(workspaceID: f.scope.workspaceID, projectID: ProjectID())
        do { _ = try await f.service.configureProgress(plan, in: foreign, expectedSequence: 1); XCTFail("Foreign configure") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .scopeMismatch) }
        do { _ = try await f.service.changeProgress(.add(WorkItemDefinition(kind: .stage, title: "Synthetic")), for: run.id, in: foreign, expectedSequence: 1); XCTFail("Foreign update") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .scopeMismatch) }
        do { _ = try await f.service.progress(for: run.id, in: foreign); XCTFail("Foreign snapshot") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .scopeMismatch) }
        do { _ = try await f.service.progress(for: RunID(), in: f.scope); XCTFail("Missing run") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .missingRun) }
        let history = try await f.service.history(for: run.id, in: f.scope)
        XCTAssertEqual(history.count, 1)
        await f.service.shutdown()
        do { _ = try await f.service.configureProgress(plan, in: f.scope, expectedSequence: 1); XCTFail("Closed configure") }
        catch { XCTAssertEqual(error as? RunLifecycleError, .closed) }
    }

    func testEqualFractionalInstantsRemainValidAfterDatabaseTimestampRounding() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let date = Date(timeIntervalSinceReferenceDate: 1_000_000_000.0000003576)
        let run = try await f.service.createRun(in: f.scope, at: date)
        _ = try await f.service.transition(run.id, in: f.scope, to: .running, expectedSequence: 1, at: date)
        let terminal = try await f.service.transition(run.id, in: f.scope, to: .completed, expectedSequence: 2, at: date)
        let history = try await f.service.history(for: run.id, in: f.scope, after: 2)
        XCTAssertEqual(history, [terminal])
    }
}
