import AgentDeskCore
import Foundation

/// Server claims only. A URI is not a local filesystem grant or permission to fetch its contents.
public struct MCPResourceDescription: Decodable, Equatable, Sendable {
    public let uri: String
    public let name: String
    public let title: String?
    public let description: String?
    public let mimeType: String?
    public let size: UInt64?
}
public struct MCPResourcePage: Sendable {
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let connectionID: UUID
    public let resources: [MCPResourceDescription]
    public let nextCursor: String?
    /// Exact unredacted wire evidence, including annotations and extensions.
    public let response: Data
}
public enum MCPResourceDiscovery {
    public static func parameters(mode: MCPProtocolMode, cursor: String? = nil) throws -> Data {
        try MCPToolDiscovery.parameters(mode: mode, cursor: cursor)
    }
    public static func decode(_ message: MCPMessage, mode: MCPProtocolMode, scope: ProjectScope,
                              environmentID: EnvironmentID, connectionID: UUID) throws -> MCPResourcePage {
        try Task.checkCancellation()
        guard case .result = message.kind else { throw MCPDiscoveryError.invalidResponse }
        do {
            let result = try ConfigurationJSON.decode(Envelope.self, from: message.bytes).result
            guard result.resources.count <= 1000, (result.nextCursor?.utf8.count ?? 0) <= 4096 else { throw MCPDiscoveryError.sizeLimit }
            if mode == .modern {
                guard result.resultType == "complete", let ttl = result.ttlMs, ttl.isFinite, ttl >= 0,
                      result.cacheScope == "public" || result.cacheScope == "private" else { throw MCPDiscoveryError.invalidResponse }
            } else if let kind = result.resultType, kind != "complete" { throw MCPDiscoveryError.invalidResponse }
            var uris = Set<String>()
            for resource in result.resources {
                try Task.checkCancellation()
                guard !resource.uri.isEmpty, resource.uri.utf8.count <= 4096,
                      !resource.uri.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }),
                      let uri = URL(string: resource.uri, encodingInvalidCharacters: false), uri.scheme != nil,
                      uris.insert(resource.uri).inserted else { throw MCPDiscoveryError.invalidResponse }
                guard !resource.name.isEmpty, resource.name.utf8.count <= 1024,
                      !resource.name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                      (resource.title?.utf8.count ?? 0) <= 1024,
                      !(resource.title?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ?? false),
                      (resource.mimeType?.utf8.count ?? 0) <= 256,
                      !(resource.mimeType?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ?? false) else {
                    throw MCPDiscoveryError.invalidResponse
                }
                guard (resource.description?.utf8.count ?? 0) <= 16_384 else { throw MCPDiscoveryError.sizeLimit }
            }
            return MCPResourcePage(scope: scope, environmentID: environmentID, connectionID: connectionID,
                resources: result.resources, nextCursor: result.nextCursor, response: message.bytes)
        } catch let error as MCPDiscoveryError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw MCPDiscoveryError.invalidResponse }
    }
    private struct Envelope: Decodable { let result: Result }
    private struct Result: Decodable {
        let resultType: String?
        let ttlMs: Double?
        let cacheScope: String?
        let resources: [MCPResourceDescription]
        let nextCursor: String?
    }
}
