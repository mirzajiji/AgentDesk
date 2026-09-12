#if os(macOS)
import AgentDeskMCP
import Foundation

/// Explicit-era handshake boundary. No server instructions or capabilities grant authority.
actor MCPNegotiatedStdioConnection {
    nonisolated let server: MCPServerDescription
    private let session: MCPStdioSession
    private init(session: MCPStdioSession, server: MCPServerDescription) { self.session = session; self.server = server }
    static func open(transport: MCPStdioTransport, mode: MCPProtocolMode, timeout: Duration = .seconds(10)) async throws -> MCPNegotiatedStdioConnection {
        let session = try MCPStdioSession(transport: transport)
        do {
            let response = try await session.request(method: mode == .modern ? "server/discover" : "initialize",
                params: MCPNegotiation.parameters(for: mode), timeout: timeout)
            let description = try MCPNegotiation.decode(response, mode: mode)
            if mode == .legacy { try await session.notify(method: "notifications/initialized") }
            try Task.checkCancellation()
            return MCPNegotiatedStdioConnection(session: session, server: description)
        } catch { await session.close(); throw error }
    }
    func ping() async throws -> MCPMessage {
        try await session.request(method: "ping", params: server.mode == .modern ? MCPNegotiation.parameters(for: .modern) : Data("{}".utf8))
    }
    func close() async { await session.close() }
}
#endif
