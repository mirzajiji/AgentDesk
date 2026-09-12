import AgentDeskCore
import Foundation

public enum MCPRequestError: Error, Equatable, Sendable {
    case invalidRequest, capacityExceeded, closed, unexpectedResponse, timedOut
}

/// Connection-local correlation only, never authorization to send or execute a method.
/// The transport owns deadline scheduling and protocol cancellation notifications.
public actor MCPRequestTracker {
    public struct Request: Sendable, Equatable {
        public let id: MCPRequestID
        public let scope: ProjectScope
        public let connectionID: UUID
        public let method: String
        public let deadline: ContinuousClock.Instant
    }
    public nonisolated let scope: ProjectScope
    public nonisolated let connectionID: UUID
    private let generation = UUID().uuidString
    private let maximumPending: Int
    private var sequence: UInt64 = 0
    private var pending: [MCPRequestID: Request] = [:]
    private var closed = false

    public init(scope: ProjectScope, connectionID: UUID, maximumPending: Int = 128) throws {
        guard (1...1024).contains(maximumPending) else { throw MCPRequestError.invalidRequest }
        self.scope = scope; self.connectionID = connectionID; self.maximumPending = maximumPending
    }
    public func begin(method: String, timeout: Duration, now: ContinuousClock.Instant = .now) throws -> Request {
        try Task.checkCancellation()
        guard !closed else { throw MCPRequestError.closed }
        guard !method.isEmpty, method.utf8.count <= 1024,
              !method.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              timeout > .zero, timeout <= .seconds(3600) else { throw MCPRequestError.invalidRequest }
        guard pending.count < maximumPending, sequence < UInt64.max else { throw MCPRequestError.capacityExceeded }
        sequence += 1
        let id = MCPRequestID.string("\(generation):\(sequence)")
        let request = Request(id: id, scope: scope, connectionID: connectionID, method: method, deadline: now.advanced(by: timeout))
        pending[id] = request
        return request
    }
    public func complete(_ response: MCPMessage, now: ContinuousClock.Instant = .now) throws -> Request {
        try Task.checkCancellation()
        guard !closed else { throw MCPRequestError.closed }
        switch response.kind {
        case .result, .error: break
        default: throw MCPRequestError.unexpectedResponse
        }
        guard let id = response.id, let request = pending.removeValue(forKey: id) else { throw MCPRequestError.unexpectedResponse }
        guard now < request.deadline else { throw MCPRequestError.timedOut }
        return request
    }
    /// Removes only this connection's request. A late response can no longer complete it.
    @discardableResult public func cancel(_ id: MCPRequestID) -> Request? { pending.removeValue(forKey: id) }
    public func expire(at now: ContinuousClock.Instant = .now) -> [Request] {
        let expired = pending.values.filter { $0.deadline <= now }
        for request in expired { pending.removeValue(forKey: request.id) }
        return expired.sorted { String(describing: $0.id) < String(describing: $1.id) }
    }
    /// The caller uses the returned requests to fail its waiters; this tracker retains no payloads.
    public func close() -> [Request] {
        closed = true
        let abandoned = Array(pending.values); pending.removeAll()
        return abandoned
    }
}
