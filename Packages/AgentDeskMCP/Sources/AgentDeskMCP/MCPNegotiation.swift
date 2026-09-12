import AgentDeskCore
import Foundation

public enum MCPProtocolMode: String, Sendable, Codable {
    case modern = "2026-07-28"
    case legacy = "2025-11-25"
}
public enum MCPNegotiationError: Error, Equatable, Sendable { case unsupportedVersion, invalidResponse }

/// Server claims, not trusted instructions or permission grants.
public struct MCPServerDescription: Sendable, Equatable {
    public let mode: MCPProtocolMode
    public let name: String?
    public let version: String?
    public let tools: Bool
    public let resources: Bool
    public let prompts: Bool
}

public enum MCPNegotiation {
    public static func parameters(for mode: MCPProtocolMode) throws -> Data {
        switch mode {
        case .modern:
            return Data(#"{"_meta":{"io.modelcontextprotocol/protocolVersion":"2026-07-28","io.modelcontextprotocol/clientInfo":{"name":"AgentDesk","version":"1"},"io.modelcontextprotocol/clientCapabilities":{}}}"#.utf8)
        case .legacy:
            return Data(#"{"protocolVersion":"2025-11-25","clientInfo":{"name":"AgentDesk","version":"1"},"capabilities":{}}"#.utf8)
        }
    }
    public static func decode(_ message: MCPMessage, mode: MCPProtocolMode) throws -> MCPServerDescription {
        guard case .result = message.kind else { throw MCPNegotiationError.invalidResponse }
        do {
            let envelope = try ConfigurationJSON.decode(Envelope.self, from: message.bytes)
            let result = envelope.result
            switch mode {
            case .modern:
                guard result.resultType == "complete", let versions = result.supportedVersions,
                      !versions.isEmpty, versions.count <= 32, versions.allSatisfy({ $0.utf8.count <= 32 }) else { throw MCPNegotiationError.invalidResponse }
                guard versions.contains(mode.rawValue) else { throw MCPNegotiationError.unsupportedVersion }
            case .legacy:
                guard result.protocolVersion == mode.rawValue else { throw MCPNegotiationError.unsupportedVersion }
                guard result.serverInfo != nil else { throw MCPNegotiationError.invalidResponse }
            }
            let identity = mode == .modern ? result._meta?.serverInfo : result.serverInfo
            if let identity {
                for text in [identity.name, identity.version] {
                    guard !text.isEmpty, text.utf8.count <= 1024,
                          !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw MCPNegotiationError.invalidResponse }
                }
            }
            return MCPServerDescription(mode: mode, name: identity?.name, version: identity?.version,
                tools: result.capabilities.tools != nil, resources: result.capabilities.resources != nil, prompts: result.capabilities.prompts != nil)
        } catch let error as MCPNegotiationError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw MCPNegotiationError.invalidResponse }
    }
    private struct Envelope: Decodable { let result: Result }
    private struct Identity: Decodable { let name: String; let version: String }
    private struct Meta: Decodable {
        let serverInfo: Identity?
        enum CodingKeys: String, CodingKey { case serverInfo = "io.modelcontextprotocol/serverInfo" }
    }
    private struct Capability: Decodable {
        private struct Key: CodingKey { let stringValue: String; let intValue: Int? = nil; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil } }
        init(from decoder: any Decoder) throws { _ = try decoder.container(keyedBy: Key.self) }
    }
    private struct Capabilities: Decodable { let tools: Capability?; let resources: Capability?; let prompts: Capability? }
    private struct Result: Decodable {
        let protocolVersion: String?
        let supportedVersions: [String]?
        let resultType: String?
        let capabilities: Capabilities
        let serverInfo: Identity?
        let _meta: Meta?
    }
}
