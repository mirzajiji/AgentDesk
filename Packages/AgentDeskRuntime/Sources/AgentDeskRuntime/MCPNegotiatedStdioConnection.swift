#if os(macOS)
import AgentDeskMCP
import Foundation

/// Process-lifetime protocol detection and handshake boundary. No server instructions or capabilities grant authority.
actor MCPNegotiatedStdioConnection {
    nonisolated let server: MCPServerDescription
    private let session: MCPStdioSession
    private init(session: MCPStdioSession, server: MCPServerDescription) { self.session = session; self.server = server }
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
            return MCPNegotiatedStdioConnection(session: session, server: description)
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
    func close() async { await session.close() }
}
#endif
