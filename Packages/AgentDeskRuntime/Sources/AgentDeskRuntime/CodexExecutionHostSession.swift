#if os(macOS)
import AgentDeskCore
import Darwin
import Foundation

/// One read-only run per verified app connection; raw observations stay within this private IPC boundary.
public actor CodexExecutionHostSession {
    typealias Factory = @Sendable (CodexExecutionStart) throws -> any ExecutionProvider
    private let factory: Factory
    private let lockDirectory: @Sendable () throws -> URL
    private var accepted = false
    private var closed = false
    private var runID: RunID?
    private var worker: Task<Void, Never>?
    private var lease: RunCoordinatorLease?
    private var events: [(event: ExecutionProviderEvent, bytes: Int)] = []
    private var bufferedBytes = 0
    private var delivered: Int64 = 0
    private var received: Int64 = 0
    private var ending: CodexExecutionHostReply?
    private var waiter: CheckedContinuation<CodexExecutionHostReply, Never>?

    public init() {
        factory = { try CodexCLIProvider(scope: $0.identity.scope, directory: $0.directory, executable: $0.executable, capacity: 64) }
        lockDirectory = { try Self.applicationLockDirectory() }
    }
    init(factory: @escaping Factory, lockDirectory: URL) {
        self.factory = factory; self.lockDirectory = { lockDirectory }
    }
    deinit { worker?.cancel(); waiter?.resume(returning: .failed(.incompleteResult)) }

    public func perform(_ data: Data) async -> Data {
        let reply: CodexExecutionHostReply
        do {
            let request = try CodexExecutionHostWire.decode(CodexExecutionHostRequest.self, from: data)
            guard request.schemaVersion == 1, !closed else { throw ExecutionProviderError.invalidRequest }
            switch request.operation {
            case .start(let start): reply = try startRun(start)
            case .next(let id, let cursor): reply = try await next(id, after: cursor)
            case .cancel(let id):
                guard id == runID else { throw ExecutionProviderError.scopeMismatch }
                await invalidate(); reply = .failed(.incompleteResult)
            }
        } catch { reply = .failed(CodexExecutionHostWire.failure(error)) }
        return (try? CodexExecutionHostWire.encode(reply)) ?? Data()
    }
    public func invalidate() async {
        closed = true
        worker?.cancel()
        waiter?.resume(returning: .failed(.incompleteResult)); waiter = nil
        if let worker { await worker.value }
        events.removeAll(); bufferedBytes = 0; lease = nil
    }
    private func startRun(_ start: CodexExecutionStart) throws -> CodexExecutionHostReply {
        try start.validate()
        guard !accepted else { throw ExecutionProviderError.busy }
        let provider = try factory(start)
        guard provider.resource == start.resource else { throw ExecutionProviderError.scopeMismatch }
        let lease = try RunCoordinatorLease(container: lockDirectory(), scope: start.identity.scope)
        accepted = true; runID = start.identity.runID; self.lease = lease
        worker = Task { [self] in
            let result: CodexExecutionHostReply
            do {
                try lease.validate(); try Task.checkCancellation()
                let execution = try await provider.start(start.request)
                defer { execution.cancel() }
                var validator = RunEventValidator(request: start.request)
                for try await event in execution.events {
                    try Task.checkCancellation(); try lease.validate()
                    guard event.identity == start.identity, event.sequence == received + 1 else { throw ExecutionProviderError.invalidProtocol }
                    // Validate serialized size before acknowledging a provider observation.
                    _ = try validator.accept(event)
                    let bytes = try CodexExecutionHostWire.encode(CodexExecutionHostReply.event(event)).count
                    try receive(event, bytes: bytes)
                }
                try Task.checkCancellation()
                _ = try validator.finish()
                result = .finished
            } catch { result = .failed(CodexExecutionHostWire.failure(error)) }
            finish(result)
        }
        return .started(start.identity, start.resource)
    }
    private func receive(_ event: ExecutionProviderEvent, bytes: Int) throws {
        received = event.sequence
        if let waiter {
            self.waiter = nil; delivered = event.sequence
            waiter.resume(returning: .event(event))
        } else {
            guard events.count < 64, bytes <= CodexExecutionHostWire.maximumBytes - bufferedBytes else { throw ExecutionProviderError.consumerOverflow }
            events.append((event, bytes)); bufferedBytes += bytes
        }
    }
    private func finish(_ result: CodexExecutionHostReply) {
        ending = result
        if let waiter { self.waiter = nil; waiter.resume(returning: result) }
        lease = nil
        worker = nil
    }
    private func next(_ id: RunID, after cursor: Int64) async throws -> CodexExecutionHostReply {
        guard accepted, id == runID, cursor == delivered, cursor >= 0 else { throw ExecutionProviderError.scopeMismatch }
        guard waiter == nil else { throw ExecutionProviderError.busy }
        if !events.isEmpty {
            let item = events.removeFirst(); delivered = item.event.sequence; bufferedBytes -= item.bytes
            return .event(item.event)
        }
        if let ending { return ending }
        return await withCheckedContinuation { waiter = $0 }
    }
    private static func applicationLockDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let directory = base.appendingPathComponent("AgentDeskCodexHost", isDirectory: true)
        var info = stat()
        if lstat(directory.path, &info) != 0 {
            guard errno == ENOENT, mkdir(directory.path, 0o700) == 0 || errno == EEXIST else { throw ExecutionProviderError.unavailable }
        }
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_uid == getuid(),
              info.st_mode & 0o077 == 0 else { throw ExecutionProviderError.unavailable }
        return directory
    }
}
#endif
