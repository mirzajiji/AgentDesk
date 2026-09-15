#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import Foundation

/// Process-lifetime protocol detection and handshake boundary. No server instructions or capabilities grant authority.
actor MCPNegotiatedStdioConnection {
    nonisolated let server: MCPServerDescription
    private let scope: ProjectScope
    private let connectionID: UUID
    private let session: MCPStdioSession
    private init(session: MCPStdioSession, server: MCPServerDescription, transport: MCPStdioTransport) {
        self.session = session; self.server = server
        self.scope = transport.scope; self.connectionID = transport.connectionID
    }
    static func open(transport: MCPStdioTransport, mode: MCPProtocolMode? = nil, timeout: Duration = .seconds(10)) async throws -> MCPNegotiatedStdioConnection {
        let session = try MCPStdioSession(transport: transport)
        do {
            let description: MCPServerDescription
            if let mode {
                description = try await handshake(session, mode: mode, timeout: timeout)
            } else {
                let probe: MCPMessage?
                do {
                    probe = try await session.request(method: "server/discover",
                        params: MCPNegotiation.parameters(for: .modern), timeout: timeout)
                } catch MCPRequestError.timedOut { probe = nil }
                if let probe, case .result = probe.kind {
                    description = try MCPNegotiation.decode(probe, mode: .modern)
                } else if let probe, case .error(let code) = probe.kind, [-32020, -32021, -32022].contains(code) {
                    // These codes identify modern semantics. Only one modern revision is implemented;
                    // a rejection cannot be resolved by silently downgrading to legacy semantics.
                    throw code == -32022 ? MCPNegotiationError.unsupportedVersion : MCPNegotiationError.invalidResponse
                } else {
                    description = try await handshake(session, mode: .legacy, timeout: timeout)
                }
            }
            try Task.checkCancellation()
            return MCPNegotiatedStdioConnection(session: session, server: description, transport: transport)
        } catch { await session.close(); throw error }
    }
    private static func handshake(_ session: MCPStdioSession, mode: MCPProtocolMode, timeout: Duration) async throws -> MCPServerDescription {
        let response = try await session.request(method: mode == .modern ? "server/discover" : "initialize",
            params: MCPNegotiation.parameters(for: mode), timeout: timeout)
        let description = try MCPNegotiation.decode(response, mode: mode)
        if mode == .legacy { try await session.notify(method: "notifications/initialized") }
        return description
    }
    func ping() async throws -> MCPMessage {
        try await session.request(method: "ping", params: server.mode == .modern ? MCPNegotiation.parameters(for: .modern) : Data("{}".utf8))
    }
    /// Internal discovery only. Callers must authorize the read and redact the completed catalog.
    func discoverTools(environmentID: EnvironmentID, timeout: Duration = .seconds(30)) async throws -> MCPToolCatalog {
        let traversal = try MCPToolPagination(scope: scope, environmentID: environmentID, connectionID: connectionID)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        do {
            while case .pending(let cursor) = await traversal.state {
                try Task.checkCancellation()
                let remaining = clock.now.duration(to: deadline)
                guard remaining > .zero else { throw MCPRequestError.timedOut }
                let response = try await session.request(method: "tools/list",
                    params: MCPToolDiscovery.parameters(mode: server.mode, cursor: cursor), timeout: remaining)
                let page = try MCPToolDiscovery.decode(response, mode: server.mode, scope: scope,
                    environmentID: environmentID, connectionID: connectionID)
                try await traversal.append(page, requestedCursor: cursor)
            }
            return try await traversal.catalog()
        } catch { await traversal.close(); throw error }
    }
    func close() async { await session.close() }
}
#endif
