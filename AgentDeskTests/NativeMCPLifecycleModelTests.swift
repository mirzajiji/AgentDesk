#if os(macOS)
import XCTest
import AgentDeskCore
import AgentDeskMCP
import AgentDeskSecurity
import AgentDeskPersistence
@testable import AgentDeskRuntime
@testable import AgentDesk

@MainActor final class NativeMCPLifecycleModelTests: XCTestCase {
    func testSeparateReviewsPrecedeStartupAndHealth() async throws {
        let fake = try LifecycleFake()
        let model = NativeMCPLifecycleModel(needsCredentials: true) { fake }
        model.prepare(); try await settle(model)
        XCTAssertEqual(fake.starts, 0); XCTAssertEqual(model.pending?.id, fake.launch.id)
        model.approve(); try await settle(model)
        XCTAssertEqual(fake.starts, 0); XCTAssertTrue(model.reviewingCredentials)
        XCTAssertEqual(model.pending?.id, fake.credential.id)
        model.approve(); try await settle(model)
        XCTAssertTrue(model.connected); XCTAssertEqual(fake.starts, 1)
        XCTAssertEqual(fake.launchID, fake.launch.id); XCTAssertEqual(fake.credentialID, fake.credential.id)
        model.checkHealth(); try await settle(model); XCTAssertEqual(fake.pings, 1)
        model.stop(); model.stop(); try await settle(model)
        XCTAssertEqual(fake.closes, 1); XCTAssertFalse(model.connected)
    }
    func testDeniedCredentialAccessNeverStartsAndCloses() async throws {
        let fake = try LifecycleFake(); fake.denyCredentials = true
        let model = NativeMCPLifecycleModel(needsCredentials: true) { fake }
        model.prepare(); try await settle(model); model.approve(); try await settle(model)
        XCTAssertEqual(fake.starts, 0); XCTAssertEqual(fake.closes, 1)
        XCTAssertNil(model.pending); XCTAssertFalse(model.connected)
    }
    func testLateStartupCannotReconnectAfterStop() async throws {
        let fake = try LifecycleFake()
        var release: CheckedContinuation<Void, Never>?
        fake.beforeStart = { await withCheckedContinuation { release = $0 } }
        let model = NativeMCPLifecycleModel(needsCredentials: false) { fake }
        model.prepare(); try await settle(model); model.approve()
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(release)
        model.stop(); release?.resume(); try await settle(model)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.connected); XCTAssertNil(model.pending); XCTAssertGreaterThan(fake.closes, 0)
    }
    func testCancelledOpenClosesLateSession() async throws {
        let fake = try LifecycleFake()
        var release: CheckedContinuation<Void, Never>?
        let model = NativeMCPLifecycleModel(needsCredentials: false) {
            await withCheckedContinuation { release = $0 }; return fake
        }
        model.prepare()
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(release); model.stop(); release?.resume(); try await settle(model)
        for _ in 0..<100 where fake.closes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fake.closes, 1); XCTAssertEqual(fake.starts, 0); XCTAssertNil(model.pending)
    }
    func testStartupFailureClosesAndDoesNotExposeRawError() async throws {
        let fake = try LifecycleFake(); fake.failStart = true
        let model = NativeMCPLifecycleModel(needsCredentials: false) { fake }
        model.prepare(); try await settle(model); model.approve(); try await settle(model)
        XCTAssertFalse(model.connected); XCTAssertEqual(fake.closes, 1)
        XCTAssertFalse(model.message.contains("private-value"))
    }
    func testStopWaitsForFailureCleanupBeforeAllowingAnotherReview() async throws {
        let fake = try LifecycleFake(); fake.failStart = true
        var release: CheckedContinuation<Void, Never>?
        fake.beforeClose = { await withCheckedContinuation { release = $0 } }
        var opens = 0
        let model = NativeMCPLifecycleModel(needsCredentials: false) { opens += 1; return fake }
        model.prepare(); try await settle(model); model.approve()
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(release)
        model.stop(); model.stop()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertTrue(model.busy, "Stop must wait for the in-flight process cleanup")
        XCTAssertEqual(model.message, "Stopping…")
        model.prepare(); XCTAssertEqual(opens, 1)
        release?.resume(); try await settle(model)
        XCTAssertEqual(fake.closes, 1); XCTAssertEqual(model.message, "Stopped.")
        XCTAssertFalse(model.connected); XCTAssertNil(model.pending)
    }
    private func settle(_ model: NativeMCPLifecycleModel) async throws {
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.busy)
    }
}
@MainActor private final class LifecycleFake: NativeMCPLifecycle {
    let launch: ApprovalRecord
    let credential: ApprovalRecord
    var starts = 0, closes = 0, pings = 0
    var launchID: UUID?, credentialID: UUID?
    var denyCredentials = false, failStart = false
    var beforeStart: (() async -> Void)?
    var beforeClose: (() async -> Void)?
    init() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let fingerprint = try ActionFingerprint(bytes: Data("synthetic".utf8))
        func pending(_ operation: PolicyOperation) throws -> ApprovalRecord {
            let action = try PolicyAction(scope: scope, environmentID: environment, operation: operation, resource: fingerprint, payload: fingerprint)
            let now = Date()
            return try ApprovalRecord(id: UUID(), action: action, requesterID: UUID(), policyFingerprint: fingerprint,
                state: .pending, sequence: 1, createdAt: now, expiresAt: now.addingTimeInterval(600), updatedAt: now,
                reviewerID: nil, reviewerRevision: nil)
        }
        launch = try pending(.runShell); credential = try pending(.readSecret)
    }
    func prepare() async throws -> PolicyPreparation { .approval(launch) }
    func review(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        XCTAssertEqual(id, launch.id); XCTAssertTrue(approve); return launch
    }
    func prepareCredentials() async throws -> PolicyPreparation {
        if denyCredentials { throw AuthorizationError.denied }; return .approval(credential)
    }
    func reviewCredentials(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        XCTAssertEqual(id, credential.id); XCTAssertTrue(approve); return credential
    }
    func start(approvalID: UUID, credentialApprovalID: UUID?) async throws -> MCPServerPresentation {
        starts += 1; launchID = approvalID; credentialID = credentialApprovalID
        await beforeStart?()
        if failStart { throw NSError(domain: "private-value", code: 1) }
        return MCPServerPresentation(mode: .modern, name: nil, version: nil, tools: false, resources: false, prompts: false)
    }
    func ping() async throws { pings += 1 }
    func close() async { closes += 1; await beforeClose?() }
}
#endif
