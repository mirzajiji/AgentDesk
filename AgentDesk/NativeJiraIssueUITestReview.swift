#if DEBUG && os(macOS)
import AgentDeskCore
import AgentDeskPlugins
import AgentDeskRuntime
import AgentDeskSecurity
import Foundation

/// Synthetic UI fixture, selected only inside the existing isolated UI-test mode.
@MainActor
final class NativeJiraIssueUITestReview: NativeJiraIssueReview {
    let pending: ApprovalRecord
    let result: JiraReadResult
    var reviewed: UUID?
    var executedApproval: UUID?
    var executions = 0
    var closes = 0
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
        guard id == pending.id, approve, expectedSequence == pending.sequence, closes == 0 else { throw AuthorizationError.invalidApproval }
        reviewed = id; return pending
    }
    func execute(approvalID: UUID?) async throws -> PolicyExecutionResult<JiraReadResult> {
        executions += 1; executedApproval = approvalID
        guard approvalID == pending.id, reviewed == pending.id, closes == 0, executions == 1 else { throw AuthorizationError.denied }
        return .executed(result)
    }
    func close() async { closes += 1 }
}

#endif
