import AgentDeskCore
import Foundation

/// Server-supplied metadata only. Discovery never inserts a prompt into project or agent instructions.
public struct MCPPromptDescription: Decodable, Equatable, Sendable {
    public let name: String
    public let title: String?
    public let description: String?
    public let arguments: [MCPPromptArgument]?
}
public struct MCPPromptArgument: Decodable, Equatable, Sendable {
    public let name: String
    public let title: String?
    public let description: String?
    public let required: Bool?
}
public struct MCPPromptPage: Sendable {
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let connectionID: UUID
    public let prompts: [MCPPromptDescription]
    public let nextCursor: String?
    /// Unredacted wire evidence; never display or persist without scoped redaction.
    public let response: Data
}

public enum MCPPromptDiscovery {
    public static func parameters(mode: MCPProtocolMode, cursor: String? = nil) throws -> Data {
        try MCPToolDiscovery.parameters(mode: mode, cursor: cursor)
    }
    public static func decode(_ message: MCPMessage, mode: MCPProtocolMode, scope: ProjectScope,
                              environmentID: EnvironmentID, connectionID: UUID) throws -> MCPPromptPage {
        try Task.checkCancellation()
        guard case .result = message.kind else { throw MCPDiscoveryError.invalidResponse }
        do {
            let result = try ConfigurationJSON.decode(Envelope.self, from: message.bytes).result
            guard result.prompts.count <= 1000, (result.nextCursor?.utf8.count ?? 0) <= 4096 else { throw MCPDiscoveryError.sizeLimit }
            if mode == .modern {
                guard result.resultType == "complete", let ttl = result.ttlMs, ttl.isFinite, ttl >= 0,
                      result.cacheScope == "public" || result.cacheScope == "private" else { throw MCPDiscoveryError.invalidResponse }
            } else if let kind = result.resultType, kind != "complete" { throw MCPDiscoveryError.invalidResponse }
            var names = Set<String>()
            for prompt in result.prompts {
                try Task.checkCancellation()
                try validate(name: prompt.name, title: prompt.title, description: prompt.description)
                guard names.insert(prompt.name).inserted else { throw MCPDiscoveryError.invalidResponse }
                guard (prompt.arguments?.count ?? 0) <= 128 else { throw MCPDiscoveryError.sizeLimit }
                var arguments = Set<String>()
                for argument in prompt.arguments ?? [] {
                    try Task.checkCancellation()
                    try validate(name: argument.name, title: argument.title, description: argument.description)
                    guard arguments.insert(argument.name).inserted else { throw MCPDiscoveryError.invalidResponse }
                }
            }
            return MCPPromptPage(scope: scope, environmentID: environmentID, connectionID: connectionID,
                prompts: result.prompts, nextCursor: result.nextCursor, response: message.bytes)
        } catch let error as MCPDiscoveryError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw MCPDiscoveryError.invalidResponse }
    }
    private static func validate(name: String, title: String?, description: String?) throws {
        guard !name.isEmpty, name.utf8.count <= 128,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              (title?.utf8.count ?? 0) <= 1024,
              !(title?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ?? false) else {
            throw MCPDiscoveryError.invalidResponse
        }
        guard (description?.utf8.count ?? 0) <= 16_384 else { throw MCPDiscoveryError.sizeLimit }
    }
    private struct Envelope: Decodable { let result: Result }
    private struct Result: Decodable {
        let resultType: String?
        let ttlMs: Double?
        let cacheScope: String?
        let prompts: [MCPPromptDescription]
        let nextCursor: String?
    }
}
