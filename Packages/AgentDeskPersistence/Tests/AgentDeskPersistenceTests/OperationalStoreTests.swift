import AgentDeskCore
import Foundation
import SQLite3
import XCTest
@testable import AgentDeskPersistence

final class OperationalStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let workspace = WorkspaceID()
        let project = ProjectID()
        var scope: ProjectScope { ProjectScope(workspaceID: workspace, projectID: project) }
        var location: URL { root.appendingPathComponent("operations.sqlite") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func store() throws -> OperationalStore { try OperationalStore(database: location, workspaceID: workspace) }
    }

    @MainActor
    func testRunAndOrderedEventReplaySurviveReopen() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try fixture.store()
        let created = try await store.createRun(in: fixture.scope, at: Date(timeIntervalSince1970: 1_000))
        _ = try await store.recordState(.running, for: created.id, in: fixture.scope, expectedSequence: 1,
                                        at: Date(timeIntervalSince1970: 1_001))
        _ = try await store.recordState(.completed, for: created.id, in: fixture.scope, expectedSequence: 2,
                                        at: Date(timeIntervalSince1970: 1_002))
        let reopened = try fixture.store()
        let record = try await reopened.run(created.id, in: fixture.scope)
        XCTAssertEqual(record?.state, .completed); XCTAssertEqual(record?.sequence, 3)
        let replay = try await reopened.events(for: created.id, in: fixture.scope, after: 1, limit: 1)
        XCTAssertEqual(replay.map(\.sequence), [2]); XCTAssertEqual(replay.first?.state, .running)
        let remaining = try await reopened.events(for: created.id, in: fixture.scope, after: 2)
        XCTAssertEqual(remaining.map(\.sequence), [3])
        let list = try await reopened.runs(in: fixture.scope)
        XCTAssertEqual(list.count, 1); XCTAssertEqual(list.first?.createdAt, created.createdAt)
    }

    @MainActor
    func testAllQueriesAndMutationsEnforceWorkspaceAndProjectScope() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try fixture.store()
        let first = try await store.createRun(in: fixture.scope)
        let otherProject = ProjectScope(workspaceID: fixture.workspace, projectID: ProjectID())
        let otherWorkspace = ProjectScope(workspaceID: WorkspaceID(), projectID: fixture.project)
        let hidden = try await store.run(first.id, in: otherProject); XCTAssertNil(hidden)
        let hiddenEvents = try await store.events(for: first.id, in: otherProject); XCTAssertTrue(hiddenEvents.isEmpty)
        do { _ = try await store.recordState(.running, for: first.id, in: otherProject, expectedSequence: 1); XCTFail("Foreign project write") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .missingRun) }
        do { _ = try await store.createRun(in: otherWorkspace); XCTFail("Foreign workspace write") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .scopeMismatch) }
        do { _ = try await store.runs(in: otherWorkspace); XCTFail("Foreign workspace read") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .scopeMismatch) }
        let second = try OperationalStore(database: fixture.location, workspaceID: otherWorkspace.workspaceID)
        _ = try await second.createRun(in: otherWorkspace, id: first.id)
        let list = try await store.runs(in: fixture.scope); XCTAssertEqual(list.count, 1)
        let visible = try await second.runs(in: otherWorkspace); XCTAssertEqual(visible.count, 1)
        XCTAssertEqual(visible.first?.scope, otherWorkspace)
    }

    @MainActor
    func testStaleAndMissingUpdatesLeaveStateAndEventsUnchanged() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try fixture.store()
        let run = try await store.createRun(in: fixture.scope)
        _ = try await store.recordState(.running, for: run.id, in: fixture.scope, expectedSequence: 1)
        do { _ = try await store.recordState(.failed, for: run.id, in: fixture.scope, expectedSequence: 1); XCTFail("Stale write") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .staleSequence) }
        do { _ = try await store.recordState(.running, for: RunID(), in: fixture.scope, expectedSequence: 1); XCTFail("Missing write") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .missingRun) }
        let record = try await store.run(run.id, in: fixture.scope); XCTAssertEqual(record?.state, .running)
        let events = try await store.events(for: run.id, in: fixture.scope); XCTAssertEqual(events.count, 2)
    }

    @MainActor
    func testConcurrentConnectionsCommitOneExpectedSequence() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let first = try fixture.store(), second = try fixture.store()
        let run = try await first.createRun(in: fixture.scope)
        let results = await withTaskGroup(of: Bool.self, returning: [Bool].self) { group in
            for store in [first, second] {
                group.addTask {
                    (try? await store.recordState(.running, for: run.id, in: run.scope, expectedSequence: 1)) != nil
                }
            }
            var results: [Bool] = []
            for await result in group { results.append(result) }
            return results
        }
        XCTAssertEqual(results.filter { $0 }.count, 1)
        let events = try await first.events(for: run.id, in: fixture.scope)
        XCTAssertEqual(events.map(\.sequence), [1, 2])
    }

    @MainActor
    func testCreateTransactionRollsBackWhenEventInsertFails() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try fixture.store()
        let connection = try SQLiteConnection(database: fixture.location)
        try connection.execute("CREATE TRIGGER fail_event BEFORE INSERT ON run_events BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        do { _ = try await store.createRun(in: fixture.scope); XCTFail("Failed transaction committed") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .database(SQLITE_CONSTRAINT)) }
        let runs = try await store.runs(in: fixture.scope); XCTAssertTrue(runs.isEmpty)
        XCTAssertEqual(try connection.integer("SELECT COUNT(*) FROM run_events"), 0)
        try connection.execute("DROP TRIGGER fail_event")
        _ = try await store.createRun(in: fixture.scope)
    }

    @MainActor
    func testCancellationRollsBackAndReleasesTransaction() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        _ = try fixture.store()
        let location = fixture.location
        let task = Task {
            let connection = try SQLiteConnection(database: location)
            try connection.transaction {
                try connection.execute("CREATE TABLE cancelled_fixture (value TEXT)")
                withUnsafeCurrentTask { $0?.cancel() }
            }
        }
        do { try await task.value; XCTFail("Cancelled transaction committed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let connection = try SQLiteConnection(database: location)
        XCTAssertEqual(try connection.integer("SELECT COUNT(*) FROM sqlite_master WHERE name = 'cancelled_fixture'"), 0)
        let store = try fixture.store()
        _ = try await store.createRun(in: fixture.scope)
    }

    @MainActor
    func testVersionOneMigrationPreservesRecordsAndCreatesSnapshotEvent() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let connection = try SQLiteConnection(database: fixture.location)
        for statement in OperationalMigrations.versionOne { try connection.execute(statement) }
        try connection.execute("PRAGMA application_id = \(OperationalMigrations.applicationID)")
        try connection.execute("PRAGMA user_version = 1")
        let id = RunID()
        try connection.execute("INSERT INTO runs VALUES (?, ?, ?, 10, 'queued')",
                               [.text(fixture.workspace.rawValue), .text(fixture.project.rawValue), .text(id.rawValue)])
        let store = try fixture.store()
        XCTAssertEqual(try connection.integer("PRAGMA user_version"), 2)
        let record = try await store.run(id, in: fixture.scope)
        XCTAssertEqual(record?.createdAt, Date(timeIntervalSince1970: 10))
        let events = try await store.events(for: id, in: fixture.scope)
        XCTAssertEqual(events.map(\.sequence), [1]); XCTAssertEqual(events.first?.state, .queued)
    }

    @MainActor
    func testFailedMigrationAndFutureSchemaAreNotReset() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let connection = try SQLiteConnection(database: fixture.location)
        for statement in OperationalMigrations.versionOne { try connection.execute(statement) }
        try connection.execute("PRAGMA application_id = \(OperationalMigrations.applicationID)")
        try connection.execute("PRAGMA user_version = 1")
        try connection.execute("CREATE TABLE run_events (synthetic_collision TEXT)")
        XCTAssertThrowsError(try fixture.store())
        XCTAssertEqual(try connection.integer("PRAGMA user_version"), 1)
        XCTAssertEqual(try connection.integer("SELECT COUNT(*) FROM sqlite_master WHERE name = 'runs'"), 1)
        try connection.execute("PRAGMA user_version = 99")
        XCTAssertThrowsError(try fixture.store()) { XCTAssertEqual($0 as? OperationalStoreError, .unsupportedSchema) }
        XCTAssertEqual(try connection.integer("PRAGMA user_version"), 99)
    }

    @MainActor
    func testForeignDatabaseAndCorruptBytesFailWithoutReset() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        do {
            let connection = try SQLiteConnection(database: fixture.location)
            try connection.execute("CREATE TABLE unrelated (value TEXT)")
            try connection.execute("INSERT INTO unrelated VALUES ('synthetic preserved data')")
        }
        XCTAssertThrowsError(try fixture.store()) { XCTAssertEqual($0 as? OperationalStoreError, .invalidDatabase) }
        do {
            let connection = try SQLiteConnection(database: fixture.location)
            XCTAssertEqual(try connection.integer("SELECT COUNT(*) FROM unrelated"), 1)
        }
        let corrupt = Data("not a SQLite database".utf8)
        try corrupt.write(to: fixture.location)
        XCTAssertThrowsError(try fixture.store())
        XCTAssertEqual(try Data(contentsOf: fixture.location), corrupt)
    }

    @MainActor
    func testSymlinksHardlinksAndSpecialDatabaseLocationsAreRejected() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let target = fixture.root.appendingPathComponent("other.sqlite")
        try Data("synthetic".utf8).write(to: target)
        try FileManager.default.createSymbolicLink(at: fixture.location, withDestinationURL: target)
        XCTAssertThrowsError(try fixture.store()) { XCTAssertEqual($0 as? OperationalStoreError, .unsafeFile) }
        try FileManager.default.removeItem(at: fixture.location)
        try FileManager.default.linkItem(at: target, to: fixture.location)
        XCTAssertThrowsError(try fixture.store()) { XCTAssertEqual($0 as? OperationalStoreError, .unsafeFile) }
        XCTAssertThrowsError(try SQLiteConnection(database: fixture.root.appendingPathComponent("unexpected.sqlite")))
        try FileManager.default.removeItem(at: fixture.location)
        try FileManager.default.createSymbolicLink(at: fixture.root.appendingPathComponent("operations.sqlite-journal"), withDestinationURL: target)
        XCTAssertThrowsError(try fixture.store()) { XCTAssertEqual($0 as? OperationalStoreError, .unsafeFile) }
        XCTAssertEqual(try Data(contentsOf: target), Data("synthetic".utf8))
    }

    @MainActor
    func testInvalidLimitsDatesAndDuplicateIDsDoNotModifyRecords() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try fixture.store()
        let run = try await store.createRun(in: fixture.scope)
        do { _ = try await store.createRun(in: fixture.scope, id: run.id); XCTFail("Duplicate ID") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .database(SQLITE_CONSTRAINT)) }
        for limit in [0, -1, 1_001] {
            do { _ = try await store.runs(in: fixture.scope, limit: limit); XCTFail("Invalid limit") }
            catch { XCTAssertEqual(error as? OperationalStoreError, .invalidInput) }
        }
        do { _ = try await store.createRun(in: fixture.scope, at: Date(timeIntervalSince1970: -1)); XCTFail("Invalid date") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .invalidInput) }
        do { _ = try await store.events(for: run.id, in: fixture.scope, after: -1); XCTFail("Invalid sequence") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .invalidInput) }
        let runs = try await store.runs(in: fixture.scope); XCTAssertEqual(runs.count, 1)
    }

    @MainActor
    func testBindingPreservesInjectionLikeTextAsData() throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let connection = try SQLiteConnection(database: fixture.location)
        try connection.execute("CREATE TABLE synthetic (value TEXT)")
        let value = "'); DROP TABLE synthetic; --"
        try connection.execute("INSERT INTO synthetic VALUES (?)", [.text(value)])
        let rows = try connection.query("SELECT value FROM synthetic") { try SQLiteConnection.text($0, 0) }
        XCTAssertEqual(rows, [value])
        XCTAssertThrowsError(try connection.execute("INSERT INTO synthetic VALUES (?)", []))
        XCTAssertEqual(try connection.integer("SELECT COUNT(*) FROM synthetic"), 1)
    }
}
