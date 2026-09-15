import AgentDeskCore
import Foundation

public enum MCPResourceReadError: Error, Equatable, Sendable {
    case invalidURI, invalidResponse, sizeLimit, inputRequired
}
public enum MCPResourceBody: Equatable, Sendable {
    case text(String), blob(Data)
}
/// Untrusted bytes and metadata. MIME claims do not authorize rendering or execution.
public struct MCPResourceContent: Equatable, Sendable {
    public let uri: String
    public let mimeType: String?
    public let body: MCPResourceBody
}
public struct MCPResourceReadResult: Sendable {
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let connectionID: UUID
    public let requestedURI: String
    public let contents: [MCPResourceContent]
    /// Exact unredacted evidence; a resource may return multiple related content URIs.
    public let response: Data
}

public enum MCPResourceRead {
    public static func parameters(mode: MCPProtocolMode, uri: String) throws -> Data {
        guard validURI(uri) else { throw MCPResourceReadError.invalidURI }
        guard var fields = try JSONSerialization.jsonObject(with: MCPToolDiscovery.parameters(mode: mode)) as? [String: Any] else {
            throw MCPResourceReadError.invalidResponse
        }
        fields["uri"] = uri
        return try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }
    public static func decode(_ message: MCPMessage, mode: MCPProtocolMode, requestedURI: String,
                              scope: ProjectScope, environmentID: EnvironmentID, connectionID: UUID) throws -> MCPResourceReadResult {
        try Task.checkCancellation()
        guard validURI(requestedURI) else { throw MCPResourceReadError.invalidURI }
        guard case .result = message.kind else { throw MCPResourceReadError.invalidResponse }
        do {
            let envelope = try ConfigurationJSON.decode(Envelope.self, from: message.bytes).result
            if envelope.resultType == "input_required" { throw MCPResourceReadError.inputRequired }
            if mode == .modern {
                guard envelope.resultType == "complete", let ttl = envelope.ttlMs, ttl.isFinite, ttl >= 0,
                      envelope.cacheScope == "public" || envelope.cacheScope == "private" else { throw MCPResourceReadError.invalidResponse }
            } else if let kind = envelope.resultType, kind != "complete" { throw MCPResourceReadError.invalidResponse }
            guard let items = envelope.contents else { throw MCPResourceReadError.invalidResponse }
            guard items.count <= 128 else { throw MCPResourceReadError.sizeLimit }
            var bytes = 0
            let contents = try items.map { item in
                try Task.checkCancellation()
                guard validURI(item.uri), (item.mimeType?.utf8.count ?? 0) <= 256,
                      !(item.mimeType?.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) ?? false) else {
                    throw MCPResourceReadError.invalidResponse
                }
                switch item.body {
                case .text(let text): bytes += text.utf8.count
                case .blob(let data): bytes += data.count
                }
                guard bytes <= 196_608 else { throw MCPResourceReadError.sizeLimit }
                return MCPResourceContent(uri: item.uri, mimeType: item.mimeType, body: item.body)
            }
            return MCPResourceReadResult(scope: scope, environmentID: environmentID, connectionID: connectionID,
                requestedURI: requestedURI, contents: contents, response: message.bytes)
        } catch let error as MCPResourceReadError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw MCPResourceReadError.invalidResponse }
    }
    private static func validURI(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 4096 &&
            !value.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || CharacterSet.controlCharacters.contains($0) }) &&
            URL(string: value, encodingInvalidCharacters: false)?.scheme != nil
    }
    private struct Envelope: Decodable { let result: Result }
    private struct Result: Decodable {
        let resultType: String?
        let ttlMs: Double?
        let cacheScope: String?
        let contents: [Item]?
    }
    private struct Item: Decodable {
        let uri: String
        let mimeType: String?
        let body: MCPResourceBody
        enum CodingKeys: String, CodingKey { case uri, mimeType, text, blob }
        init(from decoder: any Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            uri = try values.decode(String.self, forKey: .uri)
            mimeType = try values.decodeIfPresent(String.self, forKey: .mimeType)
            guard values.contains(.text) != values.contains(.blob) else { throw MCPResourceReadError.invalidResponse }
            if values.contains(.text) { body = .text(try values.decode(String.self, forKey: .text)) }
            else {
                let encoded = try values.decode(String.self, forKey: .blob)
                guard let data = Data(base64Encoded: encoded), data.base64EncodedString() == encoded else {
                    throw MCPResourceReadError.invalidResponse
                }
                body = .blob(data)
            }
        }
    }
}
