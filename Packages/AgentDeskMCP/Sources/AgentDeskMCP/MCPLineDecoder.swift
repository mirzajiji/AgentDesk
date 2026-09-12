import Foundation

/// Incremental newline framing shared by MCP stdio protocol generations.
/// A malformed, oversized or truncated stream is terminal; callers must reopen explicitly.
public struct MCPLineDecoder: Sendable {
    private let maximumBytes: Int
    private var buffer = Data()
    private var closed = false
    public init(maximumBytes: Int = 262_144) throws {
        guard (1...262_144).contains(maximumBytes) else { throw MCPWireError.invalidLimit }
        self.maximumBytes = maximumBytes
    }
    public mutating func append(_ chunk: Data) throws -> [MCPMessage] {
        guard !closed else { throw MCPWireError.streamClosed }
        do {
            try Task.checkCancellation()
            guard chunk.count <= 262_144 else { throw MCPWireError.messageTooLarge }
            var messages: [MCPMessage] = []
            for byte in chunk {
                try Task.checkCancellation()
                if byte == 10 {
                    messages.append(try MCPMessage(bytes: buffer)); buffer.removeAll(keepingCapacity: true)
                } else {
                    guard buffer.count < maximumBytes else { throw MCPWireError.messageTooLarge }
                    buffer.append(byte)
                }
            }
            return messages
        } catch { closed = true; buffer.removeAll(); throw error }
    }
    public mutating func finish() throws {
        guard !closed else { throw MCPWireError.streamClosed }
        closed = true
        guard buffer.isEmpty else { buffer.removeAll(); throw MCPWireError.truncatedMessage }
    }
}
