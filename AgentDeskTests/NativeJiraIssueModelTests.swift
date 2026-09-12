#if os(macOS)
import XCTest
import AgentDeskCore
import AgentDeskPlugins
import AgentDeskRuntime
import AgentDeskSecurity
@testable import AgentDesk

@MainActor
final class NativeJiraIssueModelTests: XCTestCase {
    func testApprovalDoesNotReadUntilApprovedAndPublishesRedactedResult() async throws {
        let fake = try IssueReviewFake()
        let model = NativeJiraIssueModel { _ in fake }
        model.identifier = "SYN-1"; model.lookup(); try await settle(model)
        XCTAssertEqual(model.pending?.id, fake.pending.id); XCTAssertEqual(fake.executions, 0)
        model.approve(); try await settle(model)
        XCTAssertEqual(fake.reviewed, fake.pending.id); XCTAssertEqual(fake.executedApproval, fake.pending.id)
        XCTAssertEqual(fake.executions, 1); XCTAssertNil(model.pending)
        XCTAssertTrue(model.content?.contains("Synthetic issue") == true)
        XCTAssertFalse(model.content?.contains("private-test-value") == true)
        XCTAssertGreaterThan(fake.closes, 0)
        model.approve(); XCTAssertEqual(fake.executions, 1)
    }
    func testCancellingPendingApprovalClosesWithoutExecution() async throws {
        let fake = try IssueReviewFake()
        let model = NativeJiraIssueModel { _ in fake }
        model.identifier = "SYN-1"; model.lookup(); try await settle(model)
        model.cancel()
        for _ in 0..<100 where fake.closes == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(fake.executions, 0); XCTAssertNil(fake.reviewed)
        XCTAssertNil(model.pending); XCTAssertNil(model.content); XCTAssertGreaterThan(fake.closes, 0)
    }
    func testLateApprovedResultCannotReappearAfterCancellation() async throws {
        let fake = try IssueReviewFake()
        var release: CheckedContinuation<Void, Never>?
        fake.beforeExecute = { await withCheckedContinuation { release = $0 } }
        let model = NativeJiraIssueModel { _ in fake }
        model.identifier = "SYN-1"; model.lookup(); try await settle(model)
        model.approve()
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(release)
        model.cancel(); release?.resume()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertNil(model.content); XCTAssertNil(model.pending); XCTAssertNil(model.message)
        XCTAssertFalse(model.busy); XCTAssertGreaterThan(fake.closes, 0)
    }
    private func settle(_ model: NativeJiraIssueModel) async throws {
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.busy)
    }
    private enum Failure: Error { case synthetic }
    func testInvalidInputDoesNotOpenAndFailureHasNoRawErrorContent() async throws {
        var calls = 0
        let model = NativeJiraIssueModel { key in
            calls += 1; XCTAssertEqual(key, "SYN-1"); throw Failure.synthetic
        }
        model.lookup(); XCTAssertEqual(calls, 0); XCTAssertFalse(model.busy)
        model.identifier = "  SYN-1  "
        model.lookup()
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls, 1); XCTAssertFalse(model.busy)
        XCTAssertNil(model.content); XCTAssertNil(model.pending)
        XCTAssertEqual(model.message, "Issue lookup failed. Check the connection, issue key and current permissions.")
    }
    func testCancelledOpeningCannotPublishLateFailure() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        let model = NativeJiraIssueModel { _ in
            await withCheckedContinuation { continuation = $0 }
            throw Failure.synthetic
        }
        model.identifier = "SYN-1"; model.lookup()
        for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(continuation); XCTAssertTrue(model.busy)
        model.cancel(); continuation?.resume()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.busy); XCTAssertNil(model.message)
        XCTAssertNil(model.content); XCTAssertNil(model.pending)
    }
}
@MainActor
private final class IssueReviewFake: NativeJiraIssueReview {
    let pending: ApprovalRecord
    let result: JiraReadResult
    var reviewed: UUID?
    var executedApproval: UUID?
    var executions = 0
    var closes = 0
    var beforeExecute: (() async -> Void)?
    init() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let fingerprint = try ActionFingerprint(bytes: Data("synthetic".utf8))
        let action = try PolicyAction(scope: scope, environmentID: environment, operation: .readEvidence,
            resource: fingerprint, payload: fingerprint)
        let now = Date()
        pending = try ApprovalRecord(id: UUID(), action: action, requesterID: UUID(), policyFingerprint: fingerprint,
            state: .pending, sequence: 1, createdAt: now, expiresAt: now.addingTimeInterval(600), updatedAt: now,
            reviewerID: nil, reviewerRevision: nil)
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let redactor = try ContentRedactor(context: context)
        result = .json(try redactor.redactText("Synthetic issue password=private-test-value", in: context))
    }
    func prepare() async throws -> PolicyPreparation { .approval(pending) }
    func review(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        XCTAssertEqual(id, pending.id); XCTAssertTrue(approve); XCTAssertEqual(expectedSequence, pending.sequence)
        reviewed = id; return pending
    }
    func execute(approvalID: UUID?) async throws -> PolicyExecutionResult<JiraReadResult> {
        executions += 1; executedApproval = approvalID
        await beforeExecute?()
        return .executed(result)
    }
    func close() async { closes += 1 }
}

#endif
