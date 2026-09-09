import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskPersistence

@MainActor
final class ApprovalStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID(), requester = UUID(), reviewer = UUID(), reviewerRevision = UUID()
        let now = Date(timeIntervalSince1970: 1_000)
        var location: URL { root.appendingPathComponent("operations.sqlite") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func store() throws -> ApprovalStore { try ApprovalStore(database: location, scope: scope, environmentID: environment) }
        func action(id: UUID = UUID(), payload: String = "synthetic") throws -> PolicyAction {
            try PolicyAction(id: id, scope: scope, environmentID: environment, operation: .writeProject,
                resource: ActionFingerprint(bytes: Data("file-id".utf8)), payload: ActionFingerprint(bytes: Data(payload.utf8)))
        }
        var policy: ActionFingerprint { try! ActionFingerprint(bytes: Data("policy revision".utf8)) }
        func prepare(_ store: ApprovalStore, action: PolicyAction) async throws -> ApprovalRecord {
            try await store.prepare(action, requesterID: requester, policy: policy, at: now, expiresAt: now.addingTimeInterval(60))
        }
        func approve(_ store: ApprovalStore, record: ApprovalRecord) async throws -> ApprovalRecord {
            try await store.review(record.id, action: record.action, policy: policy, requesterID: requester,
                reviewerID: reviewer, reviewerRevision: reviewerRevision, approve: true, expectedSequence: record.sequence, at: now.addingTimeInterval(1))
        }
    }
    func testApprovalAndOrderedAuditSurviveRestartAndAreConsumedOnce() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store(), action = try f.action()
        let prepared = try await f.prepare(store, action: action)
        let approved = try await f.approve(store, record: prepared)
        let reopened = try f.store()
        let durable = try await reopened.approval(approved.id); XCTAssertEqual(durable, approved)
        let consumed = try await reopened.consume(approved.id, action: action, policy: f.policy, requesterID: f.requester,
            expectedSequence: approved.sequence, at: f.now.addingTimeInterval(2))
        XCTAssertEqual(consumed.state, .consumed); XCTAssertEqual(consumed.reviewerRevision, f.reviewerRevision)
        let events = try await store.events(for: prepared.id); XCTAssertEqual(events.map(\.state), [.pending,.approved,.consumed])
        XCTAssertEqual(events.map(\.sequence), [1,2,3]); XCTAssertEqual(events.last?.reviewerRevision, f.reviewerRevision)
        let suffix = try await store.events(for: prepared.id, after: 1, limit: 1); XCTAssertEqual(suffix.map(\.sequence), [2])
        do { _ = try await store.consume(consumed.id, action: action, policy: f.policy, requesterID: f.requester, expectedSequence: consumed.sequence, at: f.now.addingTimeInterval(3)); XCTFail("Approval replayed") }
        catch { XCTAssertEqual(error as? AuthorizationError, .alreadyUsed) }
    }
    func testExactActionPolicyRequesterAndContextCannotBeSubstituted() async throws {
        let f = try Fixture(); defer { f.remove() }
        let store = try f.store(), original = try f.action()
        let approved = try await f.approve(store, record: f.prepare(store, action: original))
        let modified = try f.action(id: original.id, payload: "changed")
        do { _ = try await store.consume(approved.id, action: modified, policy: f.policy, requesterID: f.requester, expectedSequence: 2, at: f.now.addingTimeInterval(2)); XCTFail("Changed payload consumed approval") }
        catch { XCTAssertEqual(error as? AuthorizationError, .invalidApproval) }
        do { _ = try await store.consume(approved.id, action: original, policy: ActionFingerprint(bytes: Data()), requesterID: f.requester, expectedSequence: 2, at: f.now.addingTimeInterval(2)); XCTFail("Stale policy accepted") }
        catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        do { _ = try await store.consume(approved.id, action: original, policy: f.policy, requesterID: UUID(), expectedSequence: 2, at: f.now.addingTimeInterval(2)); XCTFail("Foreign requester accepted") }
        catch { XCTAssertEqual(error as? AuthorizationError, .invalidApproval) }
        let contexts = [(ProjectScope(workspaceID: WorkspaceID(), projectID: f.scope.projectID),f.environment),
                        (ProjectScope(workspaceID: f.scope.workspaceID, projectID: ProjectID()),f.environment),(f.scope,EnvironmentID())]
        for (scope, environment) in contexts {
            let foreign = try ApprovalStore(database: f.location, scope: scope, environmentID: environment)
            let record = try await foreign.approval(approved.id), events = try await foreign.events(for: approved.id), list = try await foreign.approvals()
            XCTAssertNil(record); XCTAssertTrue(events.isEmpty); XCTAssertTrue(list.isEmpty)
            do { _ = try await foreign.prepare(original, requesterID: f.requester, policy: f.policy, at: f.now, expiresAt: f.now.addingTimeInterval(60)); XCTFail("Foreign action stored") }
            catch { XCTAssertEqual(error as? AuthorizationError, .scopeMismatch) }
        }
        let unchanged = try await store.approval(approved.id); XCTAssertEqual(unchanged, approved)
    }
    func testExpirationRejectionIdempotencyAndClockRegressionNeverGrantExecution() async throws {
        let f = try Fixture(); defer { f.remove() }; let store = try f.store(), action = try f.action()
        let first = try await f.prepare(store, action: action)
        let duplicate = try await store.prepare(action, requesterID: f.requester, policy: f.policy, at: f.now.addingTimeInterval(1), expiresAt: f.now.addingTimeInterval(120))
        XCTAssertEqual(first, duplicate)
        do { _ = try await store.review(first.id, action: action, policy: f.policy, requesterID: f.requester, reviewerID: f.reviewer, reviewerRevision: f.reviewerRevision, approve: true, expectedSequence: 1, at: f.now.addingTimeInterval(-1)); XCTFail("Clock regression accepted") }
        catch { XCTAssertEqual(error as? AuthorizationError, .clockRegression) }
        let expired = try await store.review(first.id, action: action, policy: f.policy, requesterID: f.requester, reviewerID: f.reviewer, reviewerRevision: f.reviewerRevision, approve: true, expectedSequence: 1, at: f.now.addingTimeInterval(60))
        XCTAssertEqual(expired.state, .expired); XCTAssertNil(expired.reviewerID)
        let second = try await f.prepare(store, action: f.action())
        let rejected = try await store.review(second.id, action: second.action, policy: f.policy, requesterID: f.requester, reviewerID: f.reviewer, reviewerRevision: f.reviewerRevision, approve: false, expectedSequence: 1, at: f.now.addingTimeInterval(1))
        do { _ = try await store.consume(rejected.id, action: rejected.action, policy: f.policy, requesterID: f.requester, expectedSequence: 2, at: f.now.addingTimeInterval(2)); XCTFail("Rejected approval consumed") }
        catch { XCTAssertEqual(error as? AuthorizationError, .alreadyUsed) }
    }
    func testConcurrentConnectionsConsumeOneGrant() async throws {
        let f = try Fixture(); defer { f.remove() }; let first = try f.store(), second = try f.store()
        let approved = try await f.approve(first, record: f.prepare(first, action: f.action()))
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for store in [first,second] { group.addTask {
                (try? await store.consume(approved.id, action: approved.action, policy: f.policy, requesterID: f.requester, expectedSequence: 2, at: f.now.addingTimeInterval(2)))?.state == .consumed
            } }
            var successes = 0; for await success in group { if success { successes += 1 } }; return successes
        }
        XCTAssertEqual(count, 1)
        let events = try await first.events(for: approved.id); XCTAssertEqual(events.map(\.state), [.pending,.approved,.consumed])
    }
    func testModifyAndApprovePreservesOriginalAndRollsBackAllOnAuditFailure() async throws {
        let f = try Fixture(); defer { f.remove() }; let store = try f.store(), original = try f.action()
        let prepared = try await f.prepare(store, action: original), replacement = try f.action(payload: "reviewed replacement")
        let connection = try SQLiteConnection(database: f.location)
        try connection.execute("CREATE TRIGGER reject_review BEFORE INSERT ON approval_events WHEN NEW.state='approved' BEGIN SELECT RAISE(ABORT,'synthetic'); END")
        do { _ = try await store.replace(prepared.id, original: original, replacement: replacement, requesterID: f.requester, originalPolicy: f.policy, replacementPolicy: f.policy, reviewerID: f.reviewer, reviewerRevision: f.reviewerRevision, expectedSequence: 1, at: f.now.addingTimeInterval(1), expiresAt: f.now.addingTimeInterval(60)); XCTFail("Audit failure ignored") } catch {}
        let old = try await store.approval(prepared.id), list = try await store.approvals()
        XCTAssertEqual(old, prepared); XCTAssertEqual(list.count, 1)
        try connection.execute("DROP TRIGGER reject_review")
        let changed = try await store.replace(prepared.id, original: original, replacement: replacement, requesterID: f.requester, originalPolicy: f.policy, replacementPolicy: f.policy, reviewerID: f.reviewer, reviewerRevision: f.reviewerRevision, expectedSequence: 1, at: f.now.addingTimeInterval(1), expiresAt: f.now.addingTimeInterval(60))
        XCTAssertEqual(changed.action, replacement); XCTAssertEqual(changed.state, .approved)
        let preserved = try await store.approval(prepared.id); XCTAssertEqual(preserved?.action, original); XCTAssertEqual(preserved?.state, .modified)
        let priorEvents = try await store.events(for: prepared.id); XCTAssertEqual(priorEvents.map(\.state), [.pending,.modified])
    }
    func testCancelledWritesAndCorruptPayloadsFailClosed() async throws {
        let f = try Fixture(); defer { f.remove() }; let store = try f.store(), action = try f.action()
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await f.prepare(store, action: action) }
        do { _ = try await task.value; XCTFail("Cancelled write persisted") } catch { XCTAssertTrue(error is CancellationError) }
        let list = try await store.approvals(); XCTAssertTrue(list.isEmpty)
        let prepared = try await f.prepare(store, action: action)
        let connection = try SQLiteConnection(database: f.location)
        try connection.execute("UPDATE approvals SET action_json='{}'")
        do { _ = try await store.approval(prepared.id); XCTFail("Corrupt approval loaded") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .invalidDatabase) }
    }
    func testMigrationFromVersionThreePreservesRunsAndAddsApprovalLedger() async throws {
        let f = try Fixture(); defer { f.remove() }; let connection = try SQLiteConnection(database: f.location)
        for sql in OperationalMigrations.versionOne + OperationalMigrations.versionTwo + OperationalMigrations.versionThree { try connection.execute(sql) }
        try connection.execute("PRAGMA application_id = \(OperationalMigrations.applicationID)"); try connection.execute("PRAGMA user_version = 3")
        let run = RunID()
        try connection.execute("INSERT INTO runs VALUES (?,?,?,1000,'queued')", [.text(f.scope.workspaceID.rawValue),.text(f.scope.projectID.rawValue),.text(run.rawValue)])
        let store = try f.store(); _ = try await f.prepare(store, action: f.action())
        XCTAssertEqual(try connection.integer("PRAGMA user_version"), 4)
        XCTAssertEqual(try connection.integer("SELECT count(*) FROM runs"), 1)
        XCTAssertEqual(try connection.integer("SELECT count(*) FROM approvals"), 1)
    }
}
