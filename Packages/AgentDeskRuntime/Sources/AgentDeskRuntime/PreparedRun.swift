import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

enum RunCoordinatorError: String, Error, Sendable {
    case busy, closed, invalidPreparation, unsafeStorage, unauthorized, invalidEvents, limitExceeded
    case providerFailed, repositoryFailed, timedOut, cancelled, interrupted, persistenceUnavailable
}
struct PreparedRun: Sendable {
    let token: UUID
    let runID: RunID
    let action: PolicyAction
    let approval: ApprovalRecord?
    let maximumActivities: Int
}
struct RunOutcome: Sendable {
    let runID: RunID
    /// Nil means the terminal state could not be committed; it must not be displayed as confirmed.
    let state: RunState?
    let failure: RunCoordinatorError?
    let finalArtifactID: UUID?
}
struct RunExecution: Sendable {
    let runID: RunID
    private let task: Task<RunOutcome, Never>
    init(runID: RunID, task: Task<RunOutcome, Never>) { self.runID = runID; self.task = task }
    func result() async -> RunOutcome { await task.value }
    func cancel() { task.cancel() }
}
struct PreparedRunData: Sendable {
    let preview: PreparedRun
    let request: ExecutionRequest
    let requesterID: UUID
    let policy: ActionFingerprint
    let authority: ActionFingerprint
    let redactor: ContentRedactor
    let evidence: EvidenceStore
    let repository: (any RunRepositoryCapturing)?
    let stages: [WorkItemDefinition]
    var context: RedactionContext { evidence.context }
}

/// Only sanitized instructions/task/configuration are bound and persisted. No raw secret digest is saved.
struct RunInputSnapshot: Encodable {
    struct Source: Encodable {
        let id: String
        let layer: String
        let revision: Int
        let relativeFile: String
        let sanitizedFingerprint: ActionFingerprint
    }
    let schemaVersion = 1
    let configuration: EffectiveExecutionConfiguration
    let instructions: String
    let task: String
    let sources: [Source]
    let resource: ExecutionResource
    let maximumActivities: Int
    let executionFingerprint: ActionFingerprint
}

/// Binds the exact sanitized dispatch independently of display redaction of configuration/schema fields.
struct RunDispatchBinding: Encodable {
    let identity: ExecutionIdentity
    let instructions: String
    let task: String
    let model: String?
    let timeoutSeconds: Int
    let maximumActivities: Int
    let maximumOutputBytes: Int
    let outputSchema: OutputSchema?
    init(request: ExecutionRequest, timeoutSeconds: Int) {
        identity = request.identity; instructions = request.instructions; task = request.task; model = request.model
        self.timeoutSeconds = timeoutSeconds; maximumActivities = request.maximumActivities
        maximumOutputBytes = request.maximumOutputBytes; outputSchema = request.outputSchema
    }
}
