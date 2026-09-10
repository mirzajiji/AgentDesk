#if os(macOS)
import AgentDeskCore
import Foundation
import Synchronization

private final class HostExecutionCancellation: Sendable {
    private struct State { var task: Task<Void, Never>?; var cancelled = false }
    private let state = Mutex(State())
    func install(_ task: Task<Void, Never>) {
        state.withLock { if $0.cancelled { task.cancel() } else { $0.task = task } }
    }
    func cancel() { state.withLock { $0.cancelled = true; $0.task?.cancel() } }
    func release() { state.withLock { $0.task = nil } }
}

/// Internal provider adapter. Only RunCoordinator dispatches a policy-authorized request here.
actor CodexHostExecutionProvider: ExecutionProvider {
    nonisolated let resource: ExecutionResource
    private let directory: URL
    private let executable: URL
    private let files: GitRepositoryFiles
    private let connectionFactory: @Sendable () async -> any CodexExecutionConnection
    private var active: UUID?
    init(scope: ProjectScope, directory: URL, executable: URL,
         connectionFactory: @escaping @Sendable () async -> any CodexExecutionConnection = { CodexExecutionHostConnection() }) throws {
        let files = try GitRepositoryFiles(root: directory)
        resource = try files.resource(in: scope); self.files = files; self.directory = files.root
        self.executable = executable; self.connectionFactory = connectionFactory
    }
    func start(_ request: ExecutionRequest) async throws -> ProviderExecution {
        try Task.checkCancellation(); try files.validateRoot()
        guard request.identity.scope == resource.scope else { throw ExecutionProviderError.scopeMismatch }
        guard active == nil else { throw ExecutionProviderError.busy }
        let start = try CodexExecutionStart(request: request, directory: directory, executable: executable, resource: resource)
        let id = UUID(), cancellation = HostExecutionCancellation()
        active = id
        let (stream, continuation) = AsyncThrowingStream<ExecutionProviderEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(64))
        let task = Task { [self] in
            let connection = await connectionFactory()
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [self] in try await pump(start, connection: connection, continuation: continuation) }
                    group.addTask {
                        try await Task.sleep(for: request.timeout)
                        throw ExecutionProviderError.timedOut
                    }
                    defer { group.cancelAll() }
                    _ = try await group.next()
                }
                continuation.finish()
            } catch is CancellationError { continuation.finish(throwing: CancellationError()) }
            catch { continuation.finish(throwing: CodexExecutionHostWire.failure(error)) }
            await connection.close()
            if active == id { active = nil }
            cancellation.release()
        }
        cancellation.install(task)
        continuation.onTermination = { _ in cancellation.cancel() }
        return ProviderExecution(events: stream, cancellation: { cancellation.cancel() })
    }
    private func pump(_ start: CodexExecutionStart, connection: any CodexExecutionConnection,
                      continuation: AsyncThrowingStream<ExecutionProviderEvent, any Error>.Continuation) async throws {
        try Task.checkCancellation()
        let reply = try await send(.start(start), connection: connection)
        guard case .started(let identity, let resource) = reply, identity == start.identity, resource == self.resource else {
            if case .failed(let error) = reply { throw error }
            throw ExecutionProviderError.invalidProtocol
        }
        var cursor: Int64 = 0
        while true {
            try Task.checkCancellation(); try files.validateRoot()
            switch try await send(.next(runID: start.identity.runID, afterSequence: cursor), connection: connection) {
            case .event(let event):
                guard event.identity == start.identity, event.sequence == cursor + 1, cursor < 4_000 else { throw ExecutionProviderError.invalidProtocol }
                cursor = event.sequence
                switch continuation.yield(event) {
                case .enqueued: break
                case .dropped: throw ExecutionProviderError.consumerOverflow
                case .terminated: throw CancellationError()
                @unknown default: throw ExecutionProviderError.consumerOverflow
                }
            case .finished: try files.validateRoot(); return
            case .failed(let error): throw error
            case .started: throw ExecutionProviderError.invalidProtocol
            }
        }
    }
    private func send(_ operation: CodexExecutionHostRequest.Operation, connection: any CodexExecutionConnection) async throws -> CodexExecutionHostReply {
        let bytes = try CodexExecutionHostWire.encode(CodexExecutionHostRequest(operation))
        return try await CodexExecutionHostWire.decode(CodexExecutionHostReply.self, from: connection.send(bytes))
    }
}
#endif
