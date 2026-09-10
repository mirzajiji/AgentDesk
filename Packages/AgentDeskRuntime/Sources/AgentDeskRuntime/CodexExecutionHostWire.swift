#if os(macOS)
import AgentDeskCore
import Foundation

/// Local signed-process transport only. This is deliberately not part of the mobile protocol.
struct CodexExecutionStart: Codable, Sendable {
    let identity: ExecutionIdentity
    let directory: URL
    let executable: URL
    let resource: ExecutionResource
    let instructions: String
    let task: String
    let model: String?
    let timeoutSeconds: Int
    let maximumActivities: Int
    let maximumOutputBytes: Int
    let outputSchema: OutputSchema?
    init(request: ExecutionRequest, directory: URL, executable: URL, resource: ExecutionResource) throws {
        try request.validate()
        let seconds = request.timeout.components
        guard seconds.attoseconds == 0 else { throw ExecutionProviderError.invalidRequest }
        identity = request.identity; self.directory = directory; self.executable = executable; self.resource = resource
        instructions = request.instructions; task = request.task; model = request.model; timeoutSeconds = Int(seconds.seconds)
        maximumActivities = request.maximumActivities; maximumOutputBytes = request.maximumOutputBytes; outputSchema = request.outputSchema
        try validate()
    }
    func validate() throws {
        guard resource.scope == identity.scope, (1...128).contains(maximumActivities), (1...3_600).contains(timeoutSeconds) else {
            throw ExecutionProviderError.invalidRequest
        }
        for path in [directory, executable] {
            guard path.isFileURL, path.path.hasPrefix("/"), path.path.utf8.count <= 4_096,
                  !path.path.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
                throw ExecutionProviderError.invalidRequest
            }
        }
        try request.validate()
    }
    var request: ExecutionRequest {
        ExecutionRequest(identity: identity, instructions: instructions, task: task, model: model, timeout: .seconds(timeoutSeconds),
            maximumActivities: maximumActivities, maximumOutputBytes: maximumOutputBytes, outputSchema: outputSchema)
    }
}
struct CodexExecutionHostRequest: Codable, Sendable {
    enum Operation: Codable, Sendable {
        case start(CodexExecutionStart)
        case next(runID: RunID, afterSequence: Int64)
        case cancel(runID: RunID)
    }
    let schemaVersion: Int
    let operation: Operation
    init(_ operation: Operation) { schemaVersion = 1; self.operation = operation }
}
enum CodexExecutionHostReply: Codable, Sendable {
    case started(ExecutionIdentity, ExecutionResource)
    case event(ExecutionProviderEvent)
    case finished
    case failed(ExecutionProviderError)
}
enum CodexExecutionHostWire {
    static let maximumBytes = 2_097_152
    static func encode<T: Encodable>(_ value: T) throws -> Data {
        let data = try JSONEncoder().encode(value)
        guard data.count <= maximumBytes else { throw ExecutionProviderError.outputLimit }
        return data
    }
    static func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        guard data.count <= maximumBytes else { throw ExecutionProviderError.outputLimit }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw ExecutionProviderError.invalidProtocol }
    }
    static func failure(_ error: any Error) -> ExecutionProviderError {
        if error is CancellationError { return .incompleteResult }
        if error as? RunCoordinatorError == .busy { return .busy }
        return error as? ExecutionProviderError ?? .providerFailed
    }
}
#endif
