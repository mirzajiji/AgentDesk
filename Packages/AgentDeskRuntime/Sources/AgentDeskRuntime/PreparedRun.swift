import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

public enum RunCoordinatorError: String, Error, Sendable {
    case busy, closed, invalidPreparation, unsafeStorage, unauthorized, invalidEvents, limitExceeded
    case providerFailed, repositoryFailed, timedOut, cancelled, interrupted, persistenceUnavailable
}
public struct PreparedRun: Sendable {
    let token: UUID
    public let runID: RunID
    public let action: PolicyAction
    public let approval: ApprovalRecord?
    public let maximumActivities: Int
    public let knowledgeSnapshot: String?
}
public struct RunOutcome: Sendable {
    public let runID: RunID
    /// Nil means the terminal state could not be committed; it must not be displayed as confirmed.
    public let state: RunState?
    public let failure: RunCoordinatorError?
    public let finalArtifactID: UUID?
}
public struct RunExecution: Sendable {
    public let runID: RunID
    private let task: Task<RunOutcome, Never>
    init(runID: RunID, task: Task<RunOutcome, Never>) { self.runID = runID; self.task = task }
    public func result() async -> RunOutcome { await task.value }
    public func cancel() { task.cancel() }
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
    let knowledge: PreparedKnowledgeContext?
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
    let location: RunLocationSnapshot?
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

/// Nonsecret location provenance; operating-system bookmark bytes never enter a run snapshot.
struct RunLocationSnapshot: Encodable, Sendable {
    let scope: ProjectScope
    let selectedDirectory: String
    let registrationID: UUID?
    let registrationRevision: Int?
    func validate(in expected: ProjectScope) throws {
        guard scope == expected, selectedDirectory.hasPrefix("/"), selectedDirectory.utf8.count <= 4_096,
              !selectedDirectory.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (registrationID == nil) == (registrationRevision == nil),
              registrationRevision == nil || (1...1_000_000).contains(registrationRevision!) else { throw RunCoordinatorError.invalidPreparation }
    }
}
