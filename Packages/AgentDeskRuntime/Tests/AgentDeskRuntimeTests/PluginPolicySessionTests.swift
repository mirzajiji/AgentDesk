import AgentDeskCore
import AgentDeskPersistence
import AgentDeskPlugins
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class PluginPolicySessionTests: XCTestCase {
    func testApprovalRequiredThenExactEffectRunsOnlyOnce() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: XCTUnwrap(URL(string: "https://jira.example.test")), enabled: true)
        let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment,
            rules: [.init(.issuesCreate, .approval)])
        let prepared = try PreparedPluginAction(configuration: config, configurationRevision: 1, permissions: permissions,
            capability: .issuesCreate, resource: ActionFingerprint(bytes: Data("SYN".utf8)),
            payload: ActionFingerprint(bytes: Data("reviewed body".utf8)))
        let rules = PolicyOperation.allCases.map { PolicyRule($0, .allow) }
        let policy = try PolicySnapshot(
            workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
            project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
            environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID,
                projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment],
            operations: [.externalMutation], canApprove: true, expiresAt: Date().addingTimeInterval(600))
        let store = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
        let mobile = try PolicyAuthority(id: UUID(), kind: .pairedDevice(UUID()), scopes: [scope], environments: [environment],
            operations: Set(PolicyOperation.allCases), expiresAt: Date().addingTimeInterval(600))
        let readPermissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment,
            rules: [.init(.issuesRead, .allow)])
        let read = try PreparedPluginAction(configuration: config, configurationRevision: 1, permissions: readPermissions,
            capability: .issuesRead, resource: prepared.action.resource, payload: prepared.action.payload)
        XCTAssertThrowsError(try PluginPolicySession(prepared: read, policy: policy, permissions: readPermissions,
            authorities: [mobile], requesterID: mobile.id, store: store, validateCurrent: { (prepared, policy) })) { error in
            XCTAssertEqual(error as? AuthorizationError, .denied)
        }
        let context = CurrentPluginContext(prepared: prepared, policy: policy)
        let session = try PluginPolicySession(prepared: prepared, policy: policy, permissions: permissions,
            authorities: [user], requesterID: user.id, store: store, validateCurrent: { await context.read() })
        let counter = EffectCounter()
        do {
            _ = try await session.execute { _ in await counter.increment() }
            XCTFail("Unapproved plugin effect executed")
        } catch { XCTAssertEqual(error as? AuthorizationError, .approvalRequired) }
        guard case .approval(let pending) = try await session.prepare() else { return XCTFail("Missing review") }
        _ = try await session.review(pending.id, reviewerID: user.id, approve: true, expectedSequence: pending.sequence)
        let locked = try PolicySnapshot(workspace: policy.workspace, project: policy.project,
            environment: policy.environment, environmentKind: policy.environmentKind, workspaceLocked: true)
        await context.replacePolicy(locked)
        do {
            _ = try await session.execute(approvalID: pending.id) { _ in await counter.increment() }
            XCTFail("Changed base policy ignored")
        } catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        let beforeDispatch = await counter.value
        XCTAssertEqual(beforeDispatch, 0)
        await context.replacePolicy(policy)
        _ = try await session.execute(approvalID: pending.id) { action in
            XCTAssertEqual(action, prepared.action)
            await counter.increment()
        }
        do {
            _ = try await session.execute(approvalID: pending.id) { _ in await counter.increment() }
            XCTFail("Spent approval reused")
        } catch { }
        let count = await counter.value
        XCTAssertEqual(count, 1)

        let next = try PreparedPluginAction(configuration: config, configurationRevision: 1, permissions: permissions,
            capability: .issuesCreate, resource: prepared.action.resource, payload: prepared.action.payload)
        let racingContext = CurrentPluginContext(prepared: next, policy: policy)
        let racingSession = try PluginPolicySession(prepared: next, policy: policy, permissions: permissions,
            authorities: [user], requesterID: user.id, store: store, validateCurrent: { await racingContext.read() })
        guard case .approval(let nextApproval) = try await racingSession.prepare() else { return XCTFail("Missing review") }
        _ = try await racingSession.review(nextApproval.id, reviewerID: user.id, approve: true,
            expectedSequence: nextApproval.sequence)
        let checkpoint = expectation(description: "Dispatch validation paused")
        await racingContext.pauseAfterOneRead(checkpoint)
        let execution = Task {
            try await racingSession.execute(approvalID: nextApproval.id) { _ in await counter.increment() }
        }
        await fulfillment(of: [checkpoint], timeout: 2)
        await racingSession.removeAuthority(user.id)
        await racingContext.resume()
        do { _ = try await execution.value; XCTFail("Revoked requester dispatched") }
        catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
        let afterRevocation = await counter.value
        XCTAssertEqual(afterRevocation, 1)
        let consumed = try await store.approval(nextApproval.id)
        XCTAssertEqual(consumed?.state, .consumed)
    }
    func testAllowDenyAndFailedEffectDoNotBypassPermissionRules() async throws {
        for disposition: PolicyDisposition in [.allow, .deny, .approval] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: XCTUnwrap(URL(string: "https://jira.example.test")), enabled: true)
        let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment,
            rules: [.init(.issuesCreate, disposition)])
        let prepared = try PreparedPluginAction(configuration: config, configurationRevision: 1, permissions: permissions,
            capability: .issuesCreate, resource: ActionFingerprint(bytes: Data("SYN".utf8)),
            payload: ActionFingerprint(bytes: Data("reviewed body".utf8)))
        let rules = PolicyOperation.allCases.map { PolicyRule($0, .allow) }
        let policy = try PolicySnapshot(
            workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
            project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
            environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID,
                projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment],
            operations: [.externalMutation], canApprove: true, expiresAt: Date().addingTimeInterval(600))
        let store = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
        let session = try PluginPolicySession(prepared: prepared, policy: policy, permissions: permissions,
            authorities: [user], requesterID: user.id, store: store, validateCurrent: { (prepared, policy) })
        let effects = EffectCounter()
        switch disposition {
        case .allow:
            guard case .allowed = try await session.prepare() else { return XCTFail("Allowed action requested review") }
            _ = try await session.execute { _ in await effects.increment() }
            let count = await effects.value
            XCTAssertEqual(count, 1)
        case .deny:
            guard case .denied = try await session.prepare() else { return XCTFail("Denied action prepared") }
            do {
                _ = try await session.execute { _ in await effects.increment() }
                XCTFail("Denied action executed")
            } catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
            let count = await effects.value
            XCTAssertEqual(count, 0)
        case .approval:
            guard case .approval(let approval) = try await session.prepare() else { return XCTFail("Missing approval") }
            _ = try await session.review(approval.id, reviewerID: user.id, approve: true, expectedSequence: approval.sequence)
            do {
                _ = try await session.execute(approvalID: approval.id) { _ -> Bool in
                    await effects.increment()
                    throw SyntheticDispatchFailure.failed
                }
                XCTFail("Synthetic failure swallowed")
            } catch { XCTAssertTrue(error is SyntheticDispatchFailure) }
            do {
                _ = try await session.execute(approvalID: approval.id) { _ in await effects.increment() }
                XCTFail("Failed effect approval reused")
            } catch { }
            let count = await effects.value
            let record = try await store.approval(approval.id)
            XCTAssertEqual(count, 1)
            XCTAssertEqual(record?.state, .consumed)
        }
        }
    }

}

private actor EffectCounter {
    var value = 0
    func increment() { value += 1 }
}

private actor CurrentPluginContext {
    let prepared: PreparedPluginAction
    var policy: PolicySnapshot
    init(prepared: PreparedPluginAction, policy: PolicySnapshot) {
        self.prepared = prepared; self.policy = policy
    }
    private var skipReads: Int?
    private var paused: XCTestExpectation?
    private var continuation: CheckedContinuation<Void, Never>?
    func pauseAfterOneRead(_ checkpoint: XCTestExpectation) {
        skipReads = 1; paused = checkpoint
    }
    func read() async -> (PreparedPluginAction, PolicySnapshot) {
        if let remaining = skipReads {
            if remaining > 0 { skipReads = remaining - 1 }
            else {
                skipReads = nil
                await withCheckedContinuation { continuation in
                    self.continuation = continuation
                    paused?.fulfill()
                }
            }
        }
        return (prepared, policy)
    }
    func resume() { continuation?.resume(); continuation = nil }
    func replacePolicy(_ value: PolicySnapshot) { policy = value }
}

private enum SyntheticDispatchFailure: Error { case failed }
