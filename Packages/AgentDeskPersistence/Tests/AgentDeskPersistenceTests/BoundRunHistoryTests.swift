import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPersistence

@MainActor
final class BoundRunHistoryTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID(), agent = AgentID()
        var database: URL { root.appendingPathComponent("operations.sqlite") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func create(scope: ProjectScope? = nil, environment: EnvironmentID? = nil, agent: AgentID? = nil,
                    time: TimeInterval, bound: Bool = true) async throws -> StoredRun {
            let scope = scope ?? self.scope, environment = environment ?? self.environment, agent = agent ?? self.agent
            let store = try OperationalStore(database: database, workspaceID: scope.workspaceID)
            let run = try await store.createRun(in: scope, at: Date(timeIntervalSince1970: time))
            if bound {
                let context = RedactionContext(scope: scope, environmentID: environment, runID: run.id)
                let evidence = try EvidenceStore(database: database, context: context, agentID: agent)
                _ = try await evidence.register(snapshot: ContentRedactor(context: context).redactText("Synthetic snapshot", in: context),
                    agentRevision: 1, configurationFingerprint: ActionFingerprint(bytes: Data("synthetic".utf8)))
            }
            return run
        }
    }

    func testBoundHistoryFiltersBeforePaginationAndReopensWithStableTies() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let old = try await f.create(time: 10), one = try await f.create(time: 20), two = try await f.create(time: 20)
        _ = try await f.create(environment: EnvironmentID(), time: 30)
        let foreignAgent = try await f.create(agent: AgentID(), time: 30)
        _ = try await f.create(scope: .init(workspaceID: f.scope.workspaceID, projectID: ProjectID()), time: 30)
        _ = try await f.create(scope: .init(workspaceID: WorkspaceID(), projectID: f.scope.projectID), time: 30)
        _ = try await f.create(time: 100, bound: false)
        let expected = [one, two].sorted { $0.id.rawValue < $1.id.rawValue } + [old]
        let store = try OperationalStore(database: f.database, workspaceID: f.scope.workspaceID)
        var received: [StoredRun] = [], cursor: RunID?
        for _ in 0..<4 {
            let page = try await store.boundRuns(in: f.scope, environmentID: f.environment, agentID: f.agent, before: cursor, limit: 1)
            received += page
            if let last = page.last { cursor = last.id } else { break }
        }
        XCTAssertEqual(received, expected)
        let reopened = try OperationalStore(database: f.database, workspaceID: f.scope.workspaceID)
        let all = try await reopened.boundRuns(in: f.scope, environmentID: f.environment, agentID: f.agent)
        XCTAssertEqual(all, expected)
        for badCursor in [RunID(), foreignAgent.id] {
            do { _ = try await store.boundRuns(in: f.scope, environmentID: f.environment, agentID: f.agent, before: badCursor); XCTFail("Foreign/unknown cursor accepted") }
            catch { XCTAssertEqual(error as? OperationalStoreError, .invalidInput) }
        }
        for limit in [0, 101] {
            do { _ = try await store.boundRuns(in: f.scope, environmentID: f.environment, agentID: f.agent, limit: limit); XCTFail("Invalid limit accepted") }
            catch { XCTAssertEqual(error as? OperationalStoreError, .invalidInput) }
        }
        do { _ = try await store.boundRuns(in: .init(workspaceID: WorkspaceID(), projectID: f.scope.projectID), environmentID: f.environment, agentID: f.agent); XCTFail("Foreign workspace accepted") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .scopeMismatch) }
    }

    func testBoundHistoryRejectsMismatchedPersistedBinding() async throws {
        let f = try Fixture(); defer { try? FileManager.default.removeItem(at: f.root) }
        let run = try await f.create(time: 10)
        let connection = try SQLiteConnection(database: f.database)
        let raw = try XCTUnwrap(connection.query("SELECT binding_json FROM evidence_runs WHERE run_id=?", [.text(run.id.rawValue)],
            map: { try SQLiteConnection.text($0, 0, maximumBytes: 131_072) }).first)
        let corrupted = raw.replacingOccurrences(of: f.scope.projectID.rawValue, with: ProjectID().rawValue)
        XCTAssertNotEqual(corrupted, raw)
        try connection.execute("UPDATE evidence_runs SET binding_json=? WHERE run_id=?", [.text(corrupted), .text(run.id.rawValue)])
        let store = try OperationalStore(database: f.database, workspaceID: f.scope.workspaceID)
        do { _ = try await store.boundRuns(in: f.scope, environmentID: f.environment, agentID: f.agent); XCTFail("Mismatched binding disclosed") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .invalidDatabase) }
    }
}
