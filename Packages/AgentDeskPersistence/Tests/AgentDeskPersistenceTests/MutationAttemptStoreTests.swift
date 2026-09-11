import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskPersistence

@MainActor final class MutationAttemptStoreTests: XCTestCase {
    func testRestartPreservesUncertaintyAndTerminalOutcomeCannotBeRewritten() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let location = root.appendingPathComponent("operations.sqlite")
        let action = try PolicyAction(scope: scope, environmentID: environment, operation: .externalMutation,
            resource: .canonical("synthetic issue"), payload: .canonical("reviewed content"))
        let approval = UUID(), now = Date(timeIntervalSince1970: 1000)
        let store = try MutationAttemptStore(database: location, scope: scope, environmentID: environment)
        _ = try await store.begin(action, approvalID: approval, at: now)
        let reopened = try MutationAttemptStore(database: location, scope: scope, environmentID: environment)
        let pending = try await reopened.record(action.id)
        XCTAssertEqual(pending?.outcome, .unresolved)
        do { _ = try await reopened.begin(action, approvalID: approval, at: now); XCTFail("Repeated dispatch reservation") }
        catch { XCTAssertEqual(error as? AuthorizationError, .alreadyUsed) }
        do { _ = try await reopened.finish(action, approvalID: UUID(), outcome: .acknowledged, at: now); XCTFail("Wrong approval") }
        catch { XCTAssertEqual(error as? AuthorizationError, .invalidApproval) }
        do { _ = try await reopened.finish(action, approvalID: approval, outcome: .acknowledged, at: now.addingTimeInterval(-1)); XCTFail("Clock regression") }
        catch { XCTAssertEqual(error as? AuthorizationError, .clockRegression) }
        let completed = try await reopened.finish(action, approvalID: approval, outcome: .acknowledged, at: now.addingTimeInterval(1))
        XCTAssertEqual(completed.outcome, .acknowledged)
        do { _ = try await store.finish(action, approvalID: approval, outcome: .notDispatched, at: now.addingTimeInterval(2)); XCTFail("Rewrote outcome") }
        catch { XCTAssertEqual(error as? AuthorizationError, .alreadyUsed) }
        let foreign = try MutationAttemptStore(database: location, scope: scope, environmentID: EnvironmentID())
        let hidden = try await foreign.record(action.id)
        XCTAssertNil(hidden)
        do { _ = try await foreign.begin(action, approvalID: approval, at: now); XCTFail("Cross-environment write") }
        catch { XCTAssertEqual(error as? AuthorizationError, .scopeMismatch) }
    }
    func testCorruptEmbeddedScopeIsNotReturnedFromMatchingDatabaseRow() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let location = root.appendingPathComponent("operations.sqlite")
        let store = try MutationAttemptStore(database: location, scope: scope, environmentID: environment)
        let action = try PolicyAction(scope: scope, environmentID: environment, operation: .externalMutation,
            resource: .canonical("synthetic"), payload: .canonical("synthetic"))
        let record = try await store.begin(action, approvalID: UUID(), at: Date(timeIntervalSince1970: 1000))
        let foreign = try PolicyAction(id: action.id, scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()),
            environmentID: environment, operation: .externalMutation, resource: action.resource, payload: action.payload)
        let corrupt = MutationAttemptRecord(action: foreign, approvalID: record.approvalID, startedAt: record.startedAt,
            updatedAt: record.updatedAt, outcome: .unresolved)
        let database = try SQLiteConnection(database: location)
        try database.execute("UPDATE mutation_attempts SET record_json=?", [.json(String(decoding: try JSONEncoder().encode(corrupt), as: UTF8.self))])
        do { _ = try await store.record(action.id); XCTFail("Returned foreign embedded evidence") }
        catch { XCTAssertEqual(error as? OperationalStoreError, .invalidDatabase) }
    }

}
