import AgentDeskCore
import AgentDeskSecurity
import Foundation
import SQLite3
import XCTest
@testable import AgentDeskPersistence

@MainActor
final class RunRecoveryQueryTests: XCTestCase {
    func testRecoveryQueriesBoundScopeCursorAndBindingToStoredEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let database = root.appendingPathComponent("operations.sqlite"), store = try OperationalStore(database: database, workspaceID: scope.workspaceID)
        let run = try await store.createRun(in: scope)
        let context = RedactionContext(scope: scope, environmentID: EnvironmentID(), runID: run.id), agent = AgentID()
        let evidence = try EvidenceStore(database: database, context: context, agentID: agent)
        let binding = try await evidence.register(snapshot: ContentRedactor(context: context).redactText("Synthetic snapshot", in: context),
            agentRevision: 1, configurationFingerprint: ActionFingerprint(bytes: Data("synthetic".utf8)))
        let loaded = try await store.evidenceBinding(for: run.id, in: scope); XCTAssertEqual(loaded, binding)
        let otherProject = ProjectScope(workspaceID: scope.workspaceID, projectID: ProjectID())
        let missing = try await store.evidenceBinding(for: run.id, in: otherProject); XCTAssertNil(missing)
        let empty = try await store.unfinishedRuns(in: otherProject); XCTAssertTrue(empty.isEmpty)
        let after = try await store.unfinishedRuns(in: scope, afterRunID: run.id); XCTAssertTrue(after.isEmpty)
        for limit in [0, 257] {
            do { _ = try await store.unfinishedRuns(in: scope, limit: limit); XCTFail("Invalid limit") }
            catch { XCTAssertEqual(error as? OperationalStoreError, .invalidInput) }
        }
        let foreign = ProjectScope(workspaceID: WorkspaceID(), projectID: scope.projectID)
        do { _ = try await store.unfinishedRuns(in: foreign); XCTFail("Foreign workspace") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .scopeMismatch) }
        do { _ = try await store.evidenceBinding(for: run.id, in: foreign); XCTFail("Foreign binding") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .scopeMismatch) }
        var connection: OpaquePointer?
        XCTAssertEqual(sqlite3_open(database.path, &connection), SQLITE_OK)
        defer { sqlite3_close(connection) }
        // Corruption simulation uses fixed SQL and synthetic metadata only.
        XCTAssertEqual(sqlite3_exec(connection, "UPDATE evidence_runs SET environment_id='00000000-0000-0000-0000-000000000000'", nil, nil, nil), SQLITE_OK)
        do { _ = try await store.evidenceBinding(for: run.id, in: scope); XCTFail("Mismatched persisted environment") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .invalidDatabase) }
    }
}
