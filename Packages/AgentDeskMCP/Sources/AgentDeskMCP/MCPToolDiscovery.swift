import AgentDeskCore
import Foundation

public enum MCPDiscoveryError: Error, Equatable, Sendable { case invalidResponse, sizeLimit }

/// Untrusted tool metadata. Neither annotations nor successful discovery authorize execution.
public struct MCPToolDescription: Sendable, Equatable {
    public let name: String
    public let title: String?
    public let description: String?
    public let readOnlyHint: Bool?
    public let destructiveHint: Bool?
}

public struct MCPToolPage: Sendable {
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let connectionID: UUID
    public let tools: [MCPToolDescription]
    public let nextCursor: String?
    /// Exact response retains schemas, annotations and unknown extensions without numeric conversion.
    /// This is unredacted evidence; redact before display/persistence and never execute schema references.
    public let response: Data
}

public enum MCPToolDiscovery {
    public static func parameters(mode: MCPProtocolMode, cursor: String? = nil) throws -> Data {
        guard (cursor?.utf8.count ?? 0) <= 4096 else { throw MCPDiscoveryError.sizeLimit }
        var fields: [String: Any] = [:]
        if mode == .modern {
            guard let metadata = try JSONSerialization.jsonObject(with: MCPNegotiation.parameters(for: mode)) as? [String: Any] else {
                throw MCPDiscoveryError.invalidResponse
            }
            fields = metadata
        }
        if let cursor { fields["cursor"] = cursor }
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    public static func decode(_ message: MCPMessage, mode: MCPProtocolMode, scope: ProjectScope,
                              environmentID: EnvironmentID, connectionID: UUID) throws -> MCPToolPage {
        try Task.checkCancellation()
        guard case .result = message.kind else { throw MCPDiscoveryError.invalidResponse }
        do {
            let result = try ConfigurationJSON.decode(Envelope.self, from: message.bytes).result
            guard result.tools.count <= 1000, (result.nextCursor?.utf8.count ?? 0) <= 4096 else { throw MCPDiscoveryError.sizeLimit }
            if mode == .modern {
                guard result.resultType == "complete", let ttl = result.ttlMs, ttl.isFinite, ttl >= 0,
                      result.cacheScope == "public" || result.cacheScope == "private" else { throw MCPDiscoveryError.invalidResponse }
            } else if let kind = result.resultType, kind != "complete" { throw MCPDiscoveryError.invalidResponse }
            var names = Set<String>()
            let tools = try result.tools.map { tool in
                try Task.checkCancellation()
                guard !tool.name.isEmpty, tool.name.utf8.count <= 128,
                      !tool.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      names.insert(tool.name).inserted, tool.inputSchema.type == "object" else { throw MCPDiscoveryError.invalidResponse }
                for title in [tool.title, tool.annotations?.title].compactMap({ $0 }) {
                    guard title.utf8.count <= 1024, !title.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { throw MCPDiscoveryError.invalidResponse }
                }
                guard (tool.description?.utf8.count ?? 0) <= 16_384 else { throw MCPDiscoveryError.sizeLimit }
                return MCPToolDescription(name: tool.name, title: tool.title ?? tool.annotations?.title,
                    description: tool.description, readOnlyHint: tool.annotations?.readOnlyHint, destructiveHint: tool.annotations?.destructiveHint)
            }
            return MCPToolPage(scope: scope, environmentID: environmentID, connectionID: connectionID,
                tools: tools, nextCursor: result.nextCursor, response: message.bytes)
        } catch let error as MCPDiscoveryError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw MCPDiscoveryError.invalidResponse }
    }
    private struct Envelope: Decodable { let result: Result }
    private struct Result: Decodable {
        let resultType: String?
        let ttlMs: Double?
        let cacheScope: String?
        let tools: [Tool]
        let nextCursor: String?
    }
    private struct Tool: Decodable {
        let name: String
        let title: String?
        let description: String?
        let inputSchema: InputSchema
        let outputSchema: SchemaObject?
        let annotations: Annotations?
    }
    private struct InputSchema: Decodable { let type: String }
    private struct SchemaObject: Decodable {
        private struct Key: CodingKey {
            let stringValue: String; let intValue: Int? = nil
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { return nil }
        }
        init(from decoder: any Decoder) throws { _ = try decoder.container(keyedBy: Key.self) }
    }
    private struct Annotations: Decodable { let title: String?; let readOnlyHint: Bool?; let destructiveHint: Bool? }
}
