#if os(macOS)
import Foundation

protocol CodexExecutionConnection: Sendable {
    func send(_ data: Data) async throws -> Data
    func close() async
}

/// One bounded request/reply at a time on a connection authenticated in both directions.
@MainActor
final class CodexExecutionHostConnection: CodexExecutionConnection {
    private var connection: NSXPCConnection?
    private var pending: (UUID, CheckedContinuation<Data, any Error>)?
    private var closed = false
    init() {}
    isolated deinit {
        connection?.invalidate()
        pending?.1.resume(throwing: CancellationError())
    }
    func send(_ data: Data) async throws -> Data {
        try Task.checkCancellation()
        guard !closed else { throw ExecutionProviderError.unavailable }
        guard data.count <= CodexExecutionHostWire.maximumBytes else { throw ExecutionProviderError.outputLimit }
        guard pending == nil else { throw ExecutionProviderError.busy }
        let id = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let connection: NSXPCConnection
                let isNew = self.connection == nil
                if let existing = self.connection { connection = existing }
                else {
                    connection = NSXPCConnection(serviceName: CodexHostContract.serviceName)
                    connection.remoteObjectInterface = NSXPCInterface(with: CodexHostXPC.self)
                    connection.setCodeSigningRequirement(CodexHostContract.serviceRequirement)
                    connection.invalidationHandler = { [weak self] in Task { @MainActor in self?.failed() } }
                    connection.interruptionHandler = { [weak self] in Task { @MainActor in self?.failed() } }
                    self.connection = connection
                }
                pending = (id, continuation)
                if isNew { connection.activate() }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ [weak self] _ in
                    Task { @MainActor in self?.failed() }
                }) as? any CodexHostXPC else { failed(); return }
                proxy.execute(data) { [weak self] reply in
                    Task { @MainActor in self?.receive(reply, id: id) }
                }
            }
        } onCancel: { [weak self] in Task { @MainActor in self?.failed(cancellation: true) } }
    }
    func close() { failed(cancellation: true) }
    private func receive(_ reply: Data, id: UUID) {
        guard let pending, pending.0 == id else { return }
        self.pending = nil
        guard reply.count <= CodexExecutionHostWire.maximumBytes else {
            pending.1.resume(throwing: ExecutionProviderError.outputLimit); failed(); return
        }
        pending.1.resume(returning: reply)
    }
    private func failed(cancellation: Bool = false) {
        closed = true
        let pending = self.pending; self.pending = nil
        let connection = self.connection; self.connection = nil
        connection?.invalidate()
        pending?.1.resume(throwing: cancellation ? CancellationError() : ExecutionProviderError.processFailed)
    }
}
#endif
