#if os(macOS)
import AgentDeskCore
import Darwin
import Foundation
import Synchronization

private final class ProviderCancellation: Sendable {
    private struct State { var task: Task<Void, Never>?; var cancelled = false }
    private let state = Mutex(State())
    func install(_ task: Task<Void, Never>) {
        let cancelled = state.withLock { $0.task = task; return $0.cancelled }
        if cancelled { task.cancel() }
    }
    func cancel() {
        let task = state.withLock { $0.cancelled = true; return $0.task }
        task?.cancel()
    }
    func release() { state.withLock { $0.task = nil } }
}

/// Read-only local provider. It is internal until the coordinator supplies policy-authorized requests.
actor CodexCLIProvider: ExecutionProvider {
    private struct RootStamp: Equatable, Sendable { let device: Int32; let inode: UInt64 }
    let scope: ProjectScope
    private let directory: URL
    private let rootStamp: RootStamp
    private let executable: URL
    private let diagnostics: any CodexDiagnosing
    private let process: any CodexProcessExecuting
    private let capacity: Int
    private var active: (token: UUID, cancellation: ProviderCancellation)?

    init(scope: ProjectScope, directory: URL, executable: URL, capacity: Int = 128,
         diagnostics: any CodexDiagnosing = MacCodexDiagnostics(), process: any CodexProcessExecuting = MacCodexProcess()) throws {
        guard directory.isFileURL, executable.isFileURL, (1...512).contains(capacity) else { throw ExecutionProviderError.invalidRequest }
        // Reject a selected symlink before canonicalizing normal macOS ancestor aliases.
        var attributes = stat()
        guard lstat(directory.path, &attributes) == 0, attributes.st_mode & S_IFMT == S_IFDIR else { throw ExecutionProviderError.scopeMismatch }
        let canonical = directory.resolvingSymlinksInPath().standardizedFileURL
        self.scope = scope; self.directory = canonical; self.executable = executable
        self.capacity = capacity; self.diagnostics = diagnostics; self.process = process
        rootStamp = try Self.stamp(canonical)
    }
    deinit { active?.cancellation.cancel() }

    func start(_ request: ExecutionRequest) async throws -> ProviderExecution {
        try Task.checkCancellation(); try request.validate()
        guard request.identity.scope == scope else { throw ExecutionProviderError.scopeMismatch }
        guard active == nil else { throw ExecutionProviderError.busy }
        try checkRoot()
        let token = UUID(), cancellation = ProviderCancellation(), start = ContinuousClock.now
        active = (token, cancellation)
        do {
            let diagnostics = diagnostics, executable = executable
            let health = try await withThrowingTaskGroup(of: CodexDiagnosticSnapshot.self) { group in
                group.addTask { try await diagnostics.inspect(executable: executable) }
                group.addTask {
                    try await Task.sleep(for: request.timeout)
                    throw ExecutionProviderError.timedOut
                }
                defer { group.cancelAll() }
                guard let result = try await group.next() else { throw ExecutionProviderError.unavailable }
                return result
            }
            try Task.checkCancellation(); try checkRoot()
            guard health.issue == nil, let installation = health.installation else { throw ExecutionProviderError.unavailable }
            guard health.authentication == .chatGPT else { throw ExecutionProviderError.unauthenticated }
            let location = try CodexExecutableLocator.validate(installation.executable)
            guard location == (try CodexExecutableLocator.validate(executable)) else { throw ExecutionProviderError.unavailable }
            let remaining = request.timeout - (ContinuousClock.now - start)
            guard remaining > .zero else { throw ExecutionProviderError.timedOut }
            let (events, continuation) = AsyncThrowingStream<ExecutionProviderEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
            continuation.onTermination = { _ in cancellation.cancel() }
            let directory = directory, stamp = rootStamp, process = process
            let work = Task { [weak self] in
                do {
                    try await Self.execute(request, executable: location, directory: directory, stamp: stamp, process: process, timeout: remaining, continuation: continuation)
                    continuation.finish()
                } catch { continuation.finish(throwing: Self.normalized(error)) }
                cancellation.release()
                await self?.finished(token)
            }
            cancellation.install(work)
            return ProviderExecution(events: events, cancellation: { cancellation.cancel() })
        } catch {
            active = nil
            throw Self.normalized(error)
        }
    }

    private func finished(_ token: UUID) { if active?.token == token { active = nil } }
    private func checkRoot() throws { guard try Self.stamp(directory) == rootStamp else { throw ExecutionProviderError.scopeMismatch } }
    private nonisolated static func stamp(_ directory: URL) throws -> RootStamp {
        let descriptor = Darwin.open(directory.path, O_SEARCH | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ExecutionProviderError.scopeMismatch }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw ExecutionProviderError.scopeMismatch }
        return RootStamp(device: info.st_dev, inode: info.st_ino)
    }
    private nonisolated static func execute(_ request: ExecutionRequest, executable: URL, directory: URL, stamp: RootStamp,
                    process: any CodexProcessExecuting, timeout: Duration, continuation: AsyncThrowingStream<ExecutionProviderEvent, any Error>.Continuation) async throws {
        let input = MacProcessInputPipe(), profile = "agentdesk_" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        let machine = Mutex(try CodexSessionMachine(request: request, directory: directory, profile: profile))
        try input.write(CodexExecutionConfiguration.initialize.line())
        let allowed = Set(["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME"])
        var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        environment["NO_COLOR"] = "1"
        let emit: @Sendable (ExecutionProviderEvent) throws -> Void = { event in
            switch continuation.yield(event) {
            case .enqueued: break
            case .dropped: throw ExecutionProviderError.consumerOverflow
            case .terminated: throw CancellationError()
            @unknown default: throw ExecutionProviderError.consumerOverflow
            }
        }
        let exit = try await process.run(executable: executable, arguments: CodexExecutionConfiguration.arguments(directory: directory, profile: profile),
            directory: directory, environment: environment, input: input, timeout: timeout, maximumBytes: 8_388_608) { chunk in
            guard try Self.stamp(directory) == stamp else { throw ExecutionProviderError.scopeMismatch }
            if chunk.channel == .stdout {
                try machine.withLock { try $0.accept(chunk.bytes, input: input, emit: emit) }
            }
            // Stderr consumes the same byte budget but never leaves the process transport as raw text.
        }
        guard exit.code == 0, exit.signal == nil else { throw ExecutionProviderError.processFailed }
        guard try Self.stamp(directory) == stamp else { throw ExecutionProviderError.scopeMismatch }
        try Task.checkCancellation()
        try machine.withLock { try $0.finish(input: input, emit: emit) }
    }
    private nonisolated static func normalized(_ error: any Error) -> any Error {
        if error is CancellationError { return CancellationError() }
        if let error = error as? ExecutionProviderError { return error }
        if let error = error as? CodexDiagnosticIssue {
            switch error {
            case .timedOut: return ExecutionProviderError.timedOut
            case .outputLimit: return ExecutionProviderError.outputLimit
            default: return ExecutionProviderError.unavailable
            }
        }
        if error as? CodexWireError == .recordLimit { return ExecutionProviderError.outputLimit }
        return ExecutionProviderError.invalidProtocol
    }
}
#endif
