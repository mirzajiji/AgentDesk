#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import Foundation

/// Internal RPC multiplexing for an authorized transport. Negotiation and tool policy are separate.
actor MCPStdioSession {
    private struct Pending {
        let continuation: CheckedContinuation<MCPMessage, any Error>
        let deadline: Task<Void, Never>
    }
    private let transport: MCPStdioTransport
    private let tracker: MCPRequestTracker
    private var pending: [MCPRequestID: Pending] = [:]
    private var reader: Task<Void, Never>?
    private var closed = false
    init(transport: MCPStdioTransport) throws {
        self.transport = transport
        tracker = try MCPRequestTracker(scope: transport.scope, connectionID: transport.connectionID)
    }
    func request(method: String, params: Data = Data("{}".utf8), timeout: Duration = .seconds(30)) async throws -> MCPMessage {
        try Task.checkCancellation()
        guard !closed else { throw MCPProcessError.closed }
        startReader()
        let ticket = try await tracker.begin(method: method, timeout: timeout)
        let message: MCPMessage
        do {
            try Task.checkCancellation()
            guard !closed else { throw MCPProcessError.closed }
            message = try .request(id: ticket.id, method: method, params: params)
        } catch { await tracker.cancel(ticket.id); throw error }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let deadline = Task { [weak self] in
                    do { try await ContinuousClock().sleep(until: ticket.deadline) }
                    catch { return }
                    await self?.cancel(ticket.id, error: MCPRequestError.timedOut, fromDeadline: true)
                }
                pending[ticket.id] = Pending(continuation: continuation, deadline: deadline)
                Task { [weak self] in await self?.send(message, id: ticket.id) }
            }
        } onCancel: { Task { await self.cancel(ticket.id, error: CancellationError()) } }
    }
    private func startReader() {
        guard reader == nil else { return }
        let stream = transport.messages
        reader = Task { [weak self] in
            do {
                for try await message in stream { await self?.receive(message) }
                await self?.fail(MCPProcessError.closed)
            } catch { await self?.fail(error) }
        }
    }
    private func send(_ message: MCPMessage, id: MCPRequestID) async {
        guard !closed, pending[id] != nil else { return }
        do { try await transport.send(message) }
        catch { await fail(error) }
    }
    private func receive(_ message: MCPMessage) async {
        guard !closed else { return }
        switch message.kind {
        case .notification: return // Discovery/notification routing is a later session layer.
        case .request: await fail(MCPRequestError.unexpectedResponse); return
        case .result, .error: break
        }
        guard let id = message.id, pending[id] != nil else { return } // Late/uncorrelated responses never reach a caller.
        do {
            _ = try await tracker.complete(message)
            guard let call = pending.removeValue(forKey: id) else { return }
            call.deadline.cancel(); call.continuation.resume(returning: message)
        } catch { await cancel(id, error: error) }
    }
    private func cancel(_ id: MCPRequestID, error: any Error, fromDeadline: Bool = false) async {
        guard let call = pending.removeValue(forKey: id) else { return }
        if !fromDeadline { call.deadline.cancel() }
        await tracker.cancel(id)
        call.continuation.resume(throwing: error)
        // Cancellation is best-effort on the wire. Failure closes the connection and resolves other waiters.
        do {
            let encoded = try JSONEncoder().encode(id)
            let params = Data("{\"requestId\":".utf8) + encoded + Data("}".utf8)
            try await transport.send(.request(id: nil, method: "notifications/cancelled", params: params))
        } catch { await fail(error) }
    }
    private func fail(_ error: any Error) async {
        guard !closed else { return }
        closed = true
        let calls = pending.values; pending.removeAll()
        for call in calls { call.deadline.cancel(); call.continuation.resume(throwing: error) }
        _ = await tracker.close()
        await transport.close()
    }
    func close() async { await fail(MCPProcessError.closed); reader?.cancel(); reader = nil }
}
#endif
