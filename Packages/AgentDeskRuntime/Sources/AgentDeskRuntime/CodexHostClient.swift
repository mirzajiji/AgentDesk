#if os(macOS)
import Foundation

/// Native UI client for the app's signed, bundled Mac-only helper. Never connects to a network endpoint.
@MainActor
public final class CodexHostClient: CodexDiagnosing {
    private struct Pending {
        let id: UUID
        let connection: NSXPCConnection
        let continuation: CheckedContinuation<CodexDiagnosticSnapshot, any Error>
        let timeout: Task<Void, Never>
    }
    private var pending: Pending?
    public init() {}
    isolated deinit {
        pending?.timeout.cancel()
        pending?.connection.invalidate()
        pending?.continuation.resume(throwing: CancellationError())
    }

    public func inspect(executable: URL?) async throws -> CodexDiagnosticSnapshot {
        try await send(CodexHostRequest(operation: .inspect, executable: executable))
    }
    public func login(using installation: CodexInstallation) async throws -> CodexDiagnosticSnapshot {
        try await send(CodexHostRequest(operation: .login, installation: installation))
    }
    public func logout(using installation: CodexInstallation) async throws -> CodexDiagnosticSnapshot {
        try await send(CodexHostRequest(operation: .logout, installation: installation))
    }

    private func send(_ request: CodexHostRequest) async throws -> CodexDiagnosticSnapshot {
        try Task.checkCancellation(); try request.validate()
        guard pending == nil else { throw CodexDiagnosticIssue.busy }
        let data = try JSONEncoder().encode(request), id = UUID()
        guard data.count <= CodexHostContract.maximumMessageBytes else { throw CodexDiagnosticIssue.outputLimit }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let connection = NSXPCConnection(serviceName: CodexHostContract.serviceName)
                connection.remoteObjectInterface = NSXPCInterface(with: CodexHostXPC.self)
                connection.setCodeSigningRequirement(CodexHostContract.serviceRequirement)
                connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.finish(id, with: .failure(CodexDiagnosticIssue.commandFailed)) } }
                connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.finish(id, with: .failure(CodexDiagnosticIssue.commandFailed)) } }
                let timeout = Task { [weak self] in
                    do { try await Task.sleep(for: request.operation == .login ? .seconds(240) : .seconds(90)) }
                    catch { return }
                    self?.finish(id, with: .failure(CodexDiagnosticIssue.timedOut))
                }
                pending = Pending(id: id, connection: connection, continuation: continuation, timeout: timeout)
                connection.activate()
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                    Task { @MainActor in self?.finish(id, with: .failure(CodexDiagnosticIssue.commandFailed)) }
                }) as? any CodexHostXPC else { finish(id, with: .failure(CodexDiagnosticIssue.commandFailed)); return }
                proxy.perform(data) { [weak self] reply in
                    Task { @MainActor in
                        do {
                            guard reply.count <= CodexHostContract.maximumMessageBytes else { throw CodexDiagnosticIssue.outputLimit }
                            let value = try JSONDecoder().decode(CodexDiagnosticSnapshot.self, from: reply)
                            self?.finish(id, with: .success(value))
                        } catch { self?.finish(id, with: .failure(CodexDiagnosticIssue.commandFailed)) }
                    }
                }
            }
        } onCancel: { [weak self] in
            Task { @MainActor in self?.finish(id, with: .failure(CancellationError())) }
        }
    }
    private func finish(_ id: UUID, with result: Result<CodexDiagnosticSnapshot, any Error>) {
        guard let operation = pending, operation.id == id else { return }
        pending = nil
        operation.timeout.cancel(); operation.connection.invalidate(); operation.continuation.resume(with: result)
    }
}
#endif
