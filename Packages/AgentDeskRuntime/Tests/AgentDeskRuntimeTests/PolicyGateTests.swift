import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class PolicyGateTests: XCTestCase {
    private final class Clock: Sendable {
        let state = Mutex(Date(timeIntervalSince1970: 1_000))
        func now() -> Date { state.withLock { $0 } }
        func advance(_ seconds: TimeInterval) { state.withLock { $0 = $0.addingTimeInterval(seconds) } }
    }
    private struct Fixture: Sendable {
        let root: URL
        let scope: ProjectScope
        let environment: EnvironmentID
        let agent: AgentID
        let run: RunID
        let clock: Clock
        let requester: PolicyAuthority
        let reviewer: PolicyAuthority
        let policy: PolicySnapshot
        let store: ApprovalStore
        let gate: PolicyGate
        var output: URL { root.appendingPathComponent("synthetic-result.txt") }
        init() throws {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID(), agent = AgentID(), run = RunID(), clock = Clock()
            let rules = PolicyPreset.qaSafe.rules
            let policy = try PolicySnapshot(
                workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
                project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
                environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
            let requester = try PolicyAuthority(id: UUID(), kind: .agent(agent), scopes: [scope], environments: [environment], operations: Set(PolicyOperation.allCases), expiresAt: clock.now().addingTimeInterval(10_000))
            let reviewer = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment], operations: Set(PolicyOperation.allCases), canApprove: true, expiresAt: clock.now().addingTimeInterval(10_000))
            let store = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
            self.root = root; self.scope = scope; self.environment = environment; self.agent = agent; self.run = run; self.clock = clock
            self.policy = policy; self.requester = requester; self.reviewer = reviewer; self.store = store
            gate = try PolicyGate(policy: policy, authorities: [requester,reviewer], store: store, clock: { clock.now() })
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func action(id: UUID = UUID(), text: String = "synthetic approved output", operation: PolicyOperation = .writeProject) throws -> PolicyAction {
            try PolicyAction(id: id, scope: scope, environmentID: environment, runID: run, agentID: agent, operation: operation,
                resource: ActionFingerprint(bytes: Data(output.path.utf8)), payload: ActionFingerprint(bytes: Data(text.utf8)))
        }
        func approve(_ action: PolicyAction) async throws -> ApprovalRecord {
            guard case .approval(let pending) = try await gate.prepare(action, requesterID: requester.id) else { throw AuthorizationError.approvalRequired }
            return try await gate.review(pending.id, expectedAction: action, requesterID: requester.id, reviewerID: reviewer.id, approve: true, expectedSequence: pending.sequence)
        }
    }
    private actor Counter {
        private var value = 0
        func increment() { value += 1 }
        func count() -> Int { value }
    }
    private enum Failure: Error { case synthetic }

    func testReviewedPreparedFileEffectRunsOnceAndPersistsItsSpentApproval() async throws {
        let f = try Fixture(); defer { f.remove() }; let action = try f.action()
        do { _ = try await f.gate.execute(action, requesterID: f.requester.id) { _ in XCTFail("Unapproved effect ran") }; XCTFail("Missing approval accepted") }
        catch { XCTAssertEqual(error as? AuthorizationError, .approvalRequired) }
        let approved = try await f.approve(action), output = f.output, data = Data("synthetic approved output".utf8)
        let result = try await f.gate.execute(action, requesterID: f.requester.id, approvalID: approved.id) { dispatched in
            guard try dispatched.payload == ActionFingerprint(bytes: data) else { throw AuthorizationError.invalidApproval }
            try data.write(to: output); return data.count
        }
        if case .executed(let bytes) = result { XCTAssertEqual(bytes, data.count) } else { XCTFail("Approved effect became a dry run") }
        XCTAssertEqual(try Data(contentsOf: output), data)
        let stored = try await f.store.approval(approved.id); XCTAssertEqual(stored?.state, .consumed)
        do { _ = try await f.gate.execute(action, requesterID: f.requester.id, approvalID: approved.id) { _ in XCTFail("Approval replayed") }; XCTFail("Spent approval accepted") }
        catch { XCTAssertEqual(error as? AuthorizationError, .alreadyUsed) }
    }
    func testDryRunDenialAndCancellationProduceNoEffectsOrApprovalRecords() async throws {
        let f = try Fixture(); defer { f.remove() }; let action = try f.action(), counter = Counter()
        let dryRun = try await f.gate.execute(action, requesterID: f.requester.id, dryRun: true) { _ in await counter.increment() }
        if case .dryRun(let decision) = dryRun { XCTAssertEqual(decision.disposition, .approval) } else { XCTFail("Dry run executed") }
        do { _ = try await f.gate.execute(f.action(operation: .destructiveAction), requesterID: f.requester.id) { _ in await counter.increment() }; XCTFail("Denied action ran") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.gate.execute(action, requesterID: f.requester.id) { _ in await counter.increment() }
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled action ran") } catch { XCTAssertTrue(error is CancellationError) }
        let count = await counter.count(), records = try await f.store.approvals()
        XCTAssertEqual(count, 0); XCTAssertTrue(records.isEmpty); XCTAssertFalse(FileManager.default.fileExists(atPath: f.output.path))
    }
    func testChangedPayloadAndExpiredApprovalCannotDispatch() async throws {
        let f = try Fixture(); defer { f.remove() }; let action = try f.action(), approved = try await f.approve(action)
        do { _ = try await f.gate.execute(f.action(id: action.id, text: "substitution"), requesterID: f.requester.id, approvalID: approved.id) { _ in XCTFail("Changed payload ran") }; XCTFail("Changed payload accepted") }
        catch { XCTAssertEqual(error as? AuthorizationError, .invalidApproval) }
        f.clock.advance(600)
        do { _ = try await f.gate.execute(action, requesterID: f.requester.id, approvalID: approved.id) { _ in XCTFail("Expired approval ran") }; XCTFail("Expired approval accepted") }
        catch { XCTAssertEqual(error as? AuthorizationError, .expired) }
        let stored = try await f.store.approval(approved.id); XCTAssertEqual(stored?.state, .expired)
    }
    func testRevokedOrChangedReviewerAndPolicyInvalidateDispatch() async throws {
        for change in ["requester","reviewer","restored-reviewer","policy"] {
            let f = try Fixture(); defer { f.remove() }; let action = try f.action(), approved = try await f.approve(action)
            switch change {
            case "requester": await f.gate.removeAuthority(f.requester.id)
            case "reviewer": await f.gate.removeAuthority(f.reviewer.id)
            case "restored-reviewer":
                await f.gate.removeAuthority(f.reviewer.id)
                let restored = try PolicyAuthority(id: f.reviewer.id, kind: .localUser, scopes: [f.scope], environments: [f.environment], operations: Set(PolicyOperation.allCases), canApprove: true, expiresAt: f.reviewer.expiresAt)
                try await f.gate.installAuthority(restored)
            default:
                let revision = try PolicyDocument(level: .project, workspaceID: f.scope.workspaceID, projectID: f.scope.projectID, rules: f.policy.project.rules)
                try await f.gate.installPolicy(PolicySnapshot(workspace: f.policy.workspace, project: revision, environment: f.policy.environment, environmentKind: .test))
            }
            do { _ = try await f.gate.execute(action, requesterID: f.requester.id, approvalID: approved.id) { _ in XCTFail("Stale authority dispatched: \(change)") }; XCTFail("Stale approval accepted") }
            catch { XCTAssertTrue(error is AuthorizationError) }
            let stored = try await f.store.approval(approved.id); XCTAssertEqual(stored?.state, .approved)
        }
    }
    func testAgentCannotApproveAndHumanCanRejectAfterRequesterRevocation() async throws {
        let f = try Fixture(); defer { f.remove() }; let action = try f.action()
        guard case .approval(let pending) = try await f.gate.prepare(action, requesterID: f.requester.id) else { return XCTFail("No pending approval") }
        do { _ = try await f.gate.review(pending.id, expectedAction: action, requesterID: f.requester.id, reviewerID: f.requester.id, approve: true, expectedSequence: 1); XCTFail("Agent approved itself") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        await f.gate.removeAuthority(f.requester.id)
        let rejected = try await f.gate.review(pending.id, expectedAction: action, requesterID: f.requester.id, reviewerID: f.reviewer.id, approve: false, expectedSequence: 1)
        XCTAssertEqual(rejected.state, .rejected)
    }
    func testModifyAndApproveReviewsANewImmutableAction() async throws {
        let f = try Fixture(); defer { f.remove() }; let original = try f.action(), replacement = try f.action(text: "newly reviewed")
        guard case .approval(let pending) = try await f.gate.prepare(original, requesterID: f.requester.id) else { return XCTFail("No pending approval") }
        let revised = try await f.gate.replace(pending.id, original: original, replacement: replacement, requesterID: f.requester.id, reviewerID: f.reviewer.id, expectedSequence: 1)
        XCTAssertEqual(revised.action, replacement); XCTAssertEqual(revised.state, .approved)
        let result = try await f.gate.execute(replacement, requesterID: f.requester.id, approvalID: revised.id) { action in action.id }
        if case .executed(let id) = result { XCTAssertEqual(id, replacement.id) } else { XCTFail("Replacement did not execute") }
        let old = try await f.store.approval(pending.id); XCTAssertEqual(old?.state, .modified); XCTAssertEqual(old?.action, original)
    }
    func testFailedEffectCannotReuseApprovalAndConcurrentGatesDispatchOnce() async throws {
        let f = try Fixture(); defer { f.remove() }; let action = try f.action(), approved = try await f.approve(action), counter = Counter()
        let other = try PolicyGate(policy: f.policy, authorities: [f.requester,f.reviewer], store: f.store, clock: { f.clock.now() })
        let errors = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for gate in [f.gate,other] { group.addTask {
                do { _ = try await gate.execute(action, requesterID: f.requester.id, approvalID: approved.id) { _ in await counter.increment(); throw Failure.synthetic }; return false }
                catch { return error is Failure }
            } }
            var effectFailures = 0; for await failure in group { if failure { effectFailures += 1 } }; return effectFailures
        }
        XCTAssertEqual(errors, 1); let count = await counter.count(); XCTAssertEqual(count, 1)
        let record = try await f.store.approval(approved.id); XCTAssertEqual(record?.state, .consumed)
    }
}
