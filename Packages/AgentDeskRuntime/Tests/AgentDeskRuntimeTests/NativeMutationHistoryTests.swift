import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import XCTest
import Synchronization
@testable import AgentDeskRuntime

@MainActor final class NativeMutationHistoryTests: XCTestCase {
    func testLocalReadPolicyAndRevocationControlHistory() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let database = root.appendingPathComponent("operations.sqlite")
        func policy(_ disposition: PolicyDisposition) throws -> PolicySnapshot {
            let rules = [PolicyRule(.readEvidence, disposition)]
            return try PolicySnapshot(workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
                project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
                environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
        }
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment],
            operations: [.readEvidence], expiresAt: Date().addingTimeInterval(600))
        let store = try MutationAttemptStore(database: database, scope: scope, environmentID: environment)
        let action = try PolicyAction(scope: scope, environmentID: environment, operation: .externalMutation,
            resource: .canonical("synthetic"), payload: .canonical("synthetic"))
        _ = try await store.begin(action, approvalID: UUID(), at: Date())
        let service = try NativeMutationHistory(database: database, scope: scope, environmentID: environment, policy: policy(.allow), user: user)
        let page = try await service.page()
        XCTAssertEqual(page.records.map(\.action.id), [action.id])
        try await service.installPolicy(policy(.deny))
        do { _ = try await service.page(); XCTFail("Read after revocation") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        await service.close()
        do { _ = try await service.page(); XCTFail("Read after close") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        let allowed = try policy(.allow), denied = try policy(.deny)
        let calls = Mutex(0)
        let changing = try NativeMutationHistory(database: database, scope: scope, environmentID: environment,
            policy: allowed, user: user, currentPolicy: {
                let count = calls.withLock { $0 += 1; return $0 }
                return count == 1 ? allowed : denied
            })
        do { _ = try await changing.page(); XCTFail("Returned history after policy changed during read") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        XCTAssertEqual(calls.withLock { $0 }, 2)
        await changing.close()
        let unavailable = try NativeMutationHistory(database: database, scope: scope, environmentID: environment,
            policy: allowed, user: user, currentPolicy: { throw AuthorizationError.stalePolicy })
        do { _ = try await unavailable.page(); XCTFail("Used cached policy when configuration unavailable") }
        catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        await unavailable.close()
        let agent = try PolicyAuthority(id: UUID(), kind: .agent(AgentID()), scopes: [scope], environments: [environment],
            operations: [.readEvidence], expiresAt: Date().addingTimeInterval(600))
        XCTAssertThrowsError(try NativeMutationHistory(database: database, scope: scope, environmentID: environment, policy: policy(.allow), user: agent))
    }
}
