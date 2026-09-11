import Foundation
import Network

/// Loopback-only HTTP server intended behind the publisher's HTTPS reverse proxy.
public actor BrokerServer {
    private let router: BrokerRouter
    private let connectionTimeout: Duration
    private var requestBudget = BrokerRequestBudget()
    private let queue = DispatchQueue(label: "AgentDesk.JiraOAuthBroker")
    private var listener: NWListener?
    private var generation = UUID()
    private var startup: CheckedContinuation<UInt16, any Error>?
    private var connections: [UUID: (NWConnection, Task<Void, Never>)] = [:]
    public init(router: BrokerRouter) { self.router = router; connectionTimeout = .seconds(45) }
    init(router: BrokerRouter, connectionTimeout: Duration, requestBudget: BrokerRequestBudget = .init()) {
        self.router = router; self.connectionTimeout = connectionTimeout; self.requestBudget = requestBudget
    }

    public func start(port: UInt16 = 0) async throws -> UInt16 {
        guard listener == nil else { throw BrokerError.invalidRequest }
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let token = UUID(); generation = token
        listener.newConnectionHandler = { [weak self] connection in
            Task { guard let self else { connection.cancel(); return }; await self.accept(connection, token: token) }
        }
        listener.stateUpdateHandler = { [weak self] state in Task { await self?.changed(state, token: token) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { startup = $0; listener.start(queue: queue) }
        } onCancel: { listener.cancel() }
    }
    public func stop() async {
        generation = UUID()
        listener?.cancel(); listener = nil
        startup?.resume(throwing: CancellationError()); startup = nil
        let pending = Array(connections.values)
        for (connection, task) in pending { task.cancel(); connection.cancel() }
        for (_, task) in pending { await task.value }
        connections.removeAll()
    }
    private func changed(_ state: NWListener.State, token: UUID) {
        guard generation == token else { return }
        switch state {
        case .ready:
            guard let port = listener?.port?.rawValue else { return }
            startup?.resume(returning: port); startup = nil
        case .failed, .cancelled:
            startup?.resume(throwing: BrokerError.exchangeFailed); startup = nil
        default: break
        }
    }
    private func accept(_ connection: NWConnection, token: UUID) {
        guard generation == token, listener != nil, connections.count < 64 else { connection.cancel(); return }
        let id = UUID()
        let task = Task { await self.serve(connection, id: id) }
        connections[id] = (connection, task)
    }
    private func serve(_ connection: NWConnection, id: UUID) async {
        let timeout = Task {
            do {
                try await Task.sleep(for: connectionTimeout)
                connections[id]?.1.cancel()
                connection.cancel()
            } catch { }
        }
        defer { timeout.cancel(); connection.cancel(); connections.removeValue(forKey: id) }
        connection.start(queue: queue)
        do {
            guard requestBudget.admit() else {
                try await send(BrokerHTTP.serialize(.init(status: 429, data: Data("{\"error\":\"rateLimited\"}".utf8))), connection: connection)
                return
            }
            var buffer = Data()
            while true {
                try Task.checkCancellation()
                let (data, ended) = try await receive(connection)
                buffer.append(data)
                if let request = try BrokerHTTP.parse(buffer) {
                    let response = try await router.handle(method: request.method, target: request.target, body: request.body)
                    try Task.checkCancellation()
                    try await send(BrokerHTTP.serialize(response), connection: connection)
                    return
                }
                if ended { throw BrokerError.invalidRequest }
            }
        } catch {
            if !Task.isCancelled {
                try? await send(BrokerHTTP.serialize(.init(status: 400, data: Data("{\"error\":\"invalidRequest\"}".utf8))), connection: connection)
            }
        }
    }
    private func receive(_ connection: NWConnection) async throws -> (Data, Bool) {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, ended, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: (data ?? Data(), ended)) }
            }
        }
    }
    private func send(_ data: Data, connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: error) } else { continuation.resume() }
            })
        }
    }
}
