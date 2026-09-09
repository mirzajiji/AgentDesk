import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskPersistence

@MainActor
final class RunProgressStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let store: OperationalStore
        var database: URL { root.appendingPathComponent("operations.sqlite") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            store = try OperationalStore(database: root.appendingPathComponent("operations.sqlite"), workspaceID: scope.workspaceID)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }

    func testUnifiedStateAndProgressJournalReopensWithExactSequence() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.store.createRun(in: f.scope)
        let stage = WorkItemDefinition(kind: .stage, title: "Synthetic validation")
        let plan = try RunWorkPlan(scope: f.scope, runID: run.id, mode: .fixedStages, definitions: [stage])
        _ = try await f.store.configureProgress(plan, in: f.scope, expectedSequence: 1)
        _ = try await f.store.recordState(.running, for: run.id, in: f.scope, expectedSequence: 2)
        _ = try await f.store.changeProgress(.transition(stage.id, to: .running), for: run.id, in: f.scope, expectedSequence: 3)
        _ = try await f.store.changeProgress(.transition(stage.id, to: .completed), for: run.id, in: f.scope, expectedSequence: 4)
        _ = try await f.store.recordState(.completed, for: run.id, in: f.scope, expectedSequence: 5)
        let reopened = try OperationalStore(database: f.database, workspaceID: f.scope.workspaceID)
        let progress = try await reopened.progressPlan(for: run.id, in: f.scope)
        XCTAssertEqual(progress?.overallProgress?.fractionCompleted, 1)
        let events = try await reopened.events(for: run.id, in: f.scope)
        XCTAssertEqual(events.map(\.sequence), Array(1...6).map(Int64.init))
        XCTAssertEqual(events.map(\.kind), [.runState, .progress, .runState, .progress, .progress, .runState])
        XCTAssertEqual(events.last?.progress, progress)
        let snapshot = try await reopened.run(run.id, in: f.scope); XCTAssertEqual(snapshot?.sequence, 6)
    }

    func testIncompleteWorkBlocksCompletionAndCancellationFinalizesProgressAtomically() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.store.createRun(in: f.scope)
        let stage = WorkItemDefinition(kind: .stage, title: "Pending")
        let plan = try RunWorkPlan(scope: f.scope, runID: run.id, mode: .fixedStages, definitions: [stage])
        _ = try await f.store.configureProgress(plan, in: f.scope, expectedSequence: 1)
        _ = try await f.store.recordState(.running, for: run.id, in: f.scope, expectedSequence: 2)
        do { _ = try await f.store.recordState(.completed, for: run.id, in: f.scope, expectedSequence: 3); XCTFail("Incomplete completion") }
        catch { XCTAssertEqual(error as? WorkPlanError, .incompleteWork) }
        let cancelled = try await f.store.recordState(.cancelled, for: run.id, in: f.scope, expectedSequence: 3)
        XCTAssertEqual(cancelled.sequence, 4); XCTAssertEqual(cancelled.progress?.items[0].state, .cancelled)
        let events = try await f.store.events(for: run.id, in: f.scope); XCTAssertEqual(events.count, 4)
        let progress = try await f.store.progressPlan(for: run.id, in: f.scope)
        XCTAssertEqual(progress, cancelled.progress)
    }

    func testFailedEventInsertRollsBackSnapshotAndReleasesTransaction() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.store.createRun(in: f.scope)
        let stage = WorkItemDefinition(kind: .stage, title: "Synthetic")
        let plan = try RunWorkPlan(scope: f.scope, runID: run.id, mode: .fixedStages, definitions: [stage])
        _ = try await f.store.configureProgress(plan, in: f.scope, expectedSequence: 1)
        _ = try await f.store.recordState(.running, for: run.id, in: f.scope, expectedSequence: 2)
        let connection = try SQLiteConnection(database: f.database)
        try connection.execute("CREATE TRIGGER fail_progress_event BEFORE INSERT ON run_events BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        do { _ = try await f.store.changeProgress(.transition(stage.id, to: .running), for: run.id, in: f.scope, expectedSequence: 3); XCTFail("Failed transaction committed") }
        catch { XCTAssertTrue(error is OperationalStoreError) }
        let unchanged = try await f.store.progressPlan(for: run.id, in: f.scope); XCTAssertEqual(unchanged, plan)
        try connection.execute("DROP TRIGGER fail_progress_event")
        let next = try await f.store.changeProgress(.transition(stage.id, to: .running), for: run.id, in: f.scope, expectedSequence: 3)
        XCTAssertEqual(next.sequence, 4)
    }

    func testScopeStaleSequencesAndMalformedSnapshotsFailClosed() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let run = try await f.store.createRun(in: f.scope)
        let stage = WorkItemDefinition(kind: .stage, title: "Synthetic")
        let foreign = ProjectScope(workspaceID: f.scope.workspaceID, projectID: ProjectID())
        let foreignPlan = try RunWorkPlan(scope: foreign, runID: run.id, mode: .fixedStages, definitions: [stage])
        do { _ = try await f.store.configureProgress(foreignPlan, in: f.scope, expectedSequence: 1); XCTFail("Foreign plan accepted") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .scopeMismatch) }
        let plan = try RunWorkPlan(scope: f.scope, runID: run.id, mode: .fixedStages, definitions: [stage])
        _ = try await f.store.configureProgress(plan, in: f.scope, expectedSequence: 1)
        let hidden = try await f.store.progressPlan(for: run.id, in: foreign); XCTAssertNil(hidden)
        do { _ = try await f.store.changeProgress(.transition(stage.id, to: .running), for: run.id, in: f.scope, expectedSequence: 1); XCTFail("Stale update") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .staleSequence) }
        let connection = try SQLiteConnection(database: f.database)
        let copied = String(decoding: try JSONEncoder().encode(foreignPlan), as: UTF8.self)
        try connection.execute("UPDATE run_progress SET plan_json = ?", [.json(copied)])
        do { _ = try await f.store.progressPlan(for: run.id, in: f.scope); XCTFail("Copied scope read") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .invalidDatabase) }
    }

    func testVersionTwoMigrationKeepsExistingStateHistoryAndAllowsProgress() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("operations.sqlite"), scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), id = RunID()
        let connection = try SQLiteConnection(database: path)
        for statement in OperationalMigrations.versionOne { try connection.execute(statement) }
        try connection.execute("INSERT INTO runs VALUES (?, ?, ?, 10, 'queued')", [.text(scope.workspaceID.rawValue), .text(scope.projectID.rawValue), .text(id.rawValue)])
        for statement in OperationalMigrations.versionTwo { try connection.execute(statement) }
        try connection.execute("PRAGMA application_id = \(OperationalMigrations.applicationID)")
        try connection.execute("PRAGMA user_version = 2")
        let store = try OperationalStore(database: path, workspaceID: scope.workspaceID)
        let history = try await store.events(for: id, in: scope)
        XCTAssertEqual(history.count, 1); XCTAssertEqual(history[0].kind, .runState); XCTAssertNil(history[0].progress)
        XCTAssertEqual(try connection.integer("PRAGMA user_version"), 4)
        let stage = WorkItemDefinition(kind: .stage, title: "Migrated")
        _ = try await store.configureProgress(RunWorkPlan(scope: scope, runID: id, mode: .fixedStages, definitions: [stage]), in: scope, expectedSequence: 1)
        let progress = try await store.progressPlan(for: id, in: scope); XCTAssertNotNil(progress)
    }

    func testPublishedDatesMatchSQLitePrecisionIncludingProgressItemDates() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        // This fractional reference-epoch instant loses one binary digit when converted to Unix time.
        let date = Date(timeIntervalSinceReferenceDate: 1_000_000_000.0000001192)
        let run = try await f.store.createRun(in: f.scope, at: date)
        let reopenedRun = try await f.store.run(run.id, in: f.scope)
        XCTAssertEqual(run, reopenedRun)
        let stage = WorkItemDefinition(kind: .stage, title: "Synthetic precision check")
        let plan = try RunWorkPlan(scope: f.scope, runID: run.id, mode: .fixedStages, definitions: [stage])
        let configured = try await f.store.configureProgress(plan, in: f.scope, expectedSequence: 1, at: date)
        let started = try await f.store.recordState(.running, for: run.id, in: f.scope, expectedSequence: 2, at: date)
        let progress = try await f.store.changeProgress(.transition(stage.id, to: .running), for: run.id, in: f.scope, expectedSequence: 3, at: date)
        let cancelled = try await f.store.recordState(.cancelled, for: run.id, in: f.scope, expectedSequence: 4, at: date)
        let replay = try await f.store.events(for: run.id, in: f.scope, after: 1)
        XCTAssertEqual(replay, [configured, started, progress, cancelled])
    }
}
