import AgentDeskCore
import Foundation

/// Internal provider boundary. The run coordinator must authorize this context before using it.
struct ExecutionIdentity: Equatable, Sendable {
    let scope: ProjectScope
    let runID: RunID
    let agentID: AgentID
    let environmentID: EnvironmentID
}
struct ExecutionRequest: Sendable {
    let identity: ExecutionIdentity
    let instructions: String
    let task: String
    let model: String?
    let timeout: Duration
    let maximumActivities: Int

    func validate() throws {
        guard !instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !task.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              instructions.utf8.count <= 98_304, task.utf8.count <= 98_304,
              !instructions.utf8.contains(0), !task.utf8.contains(0),
              timeout > .zero, timeout <= .seconds(3_600), (1...1_000).contains(maximumActivities) else {
            throw ExecutionProviderError.invalidRequest
        }
        if let model {
            let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
            guard !model.isEmpty, model.utf8.count <= 128, model.unicodeScalars.allSatisfy(allowed.contains) else {
                throw ExecutionProviderError.invalidRequest
            }
        }
    }
}
enum ExecutionProviderError: Error, Equatable, Sendable {
    case invalidRequest, scopeMismatch, unavailable, unauthenticated, busy, outputLimit, consumerOverflow
    case invalidProtocol, unverifiedPermissions, unexpectedApproval, providerFailed, incompleteResult, processFailed, timedOut
}

/// Untrusted provider observations held in bounded memory. Redaction is required before persistence or UI.
struct ExecutionProviderEvent: Sendable, Equatable {
    enum Activity: String, Sendable { case command, fileChange, planning }
    enum Payload: Sendable, Equatable {
        case started
        case activity(id: String, kind: Activity, completed: Bool)
        case message(id: String, text: String)
        case completed(text: String)
    }
    let identity: ExecutionIdentity
    let sequence: Int64
    let payload: Payload
}
struct ProviderExecution: Sendable {
    let events: AsyncThrowingStream<ExecutionProviderEvent, any Error>
    private let cancellation: @Sendable () -> Void
    init(events: AsyncThrowingStream<ExecutionProviderEvent, any Error>, cancellation: @escaping @Sendable () -> Void) {
        self.events = events; self.cancellation = cancellation
    }
    /// Required when abandoning iteration without cancelling the consuming task.
    func cancel() { cancellation() }
}
protocol ExecutionProvider: Sendable {
    func start(_ request: ExecutionRequest) async throws -> ProviderExecution
}
