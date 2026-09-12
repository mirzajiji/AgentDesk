import AgentDeskCore
import Foundation

public enum MCPWireError: Error, Equatable, Sendable {
    case malformedMessage, messageTooLarge, invalidLimit, streamClosed, truncatedMessage
}

public enum MCPRequestID: Hashable, Sendable, Codable {
    case string(String), integer(Int64)
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self { case .string(let text): try value.encode(text); case .integer(let integer): try value.encode(integer) }
    }
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if let string = try? value.decode(String.self) {
            guard string.utf8.count <= 1024 else { throw MCPWireError.malformedMessage }
            self = .string(string)
        } else if let integer = try? value.decode(Int64.self) { self = .integer(integer) }
        else { throw MCPWireError.malformedMessage }
    }
}

/// Untrusted wire data. Retains original JSON bytes, without reserializing evidence numbers.
/// Parsing grants no permission and does not establish a negotiated protocol version.
public struct MCPMessage: Sendable {
    public enum Kind: Equatable, Sendable { case request(String), notification(String), result, error(Int) }
    public let id: MCPRequestID?
    public let kind: Kind
    public let bytes: Data
    public init(bytes: Data) throws {
        guard bytes.count <= 262_144 else { throw MCPWireError.messageTooLarge }
        do {
            let envelope = try ConfigurationJSON.decode(Envelope.self, from: bytes)
            id = envelope.id; kind = envelope.kind; self.bytes = bytes
        } catch is CancellationError { throw CancellationError() }
        catch { throw MCPWireError.malformedMessage }
    }
    public static func request(id: MCPRequestID?, method: String, params: Data = Data("{}".utf8)) throws -> MCPMessage {
        guard params.count <= 262_144 else { throw MCPWireError.messageTooLarge }
        guard !method.isEmpty, method.utf8.count <= 1024 else { throw MCPWireError.malformedMessage }
        if case .string(let value) = id, value.utf8.count > 1024 { throw MCPWireError.malformedMessage }
        let encoder = JSONEncoder()
        var bytes = Data("{\"jsonrpc\":\"2.0\",\"method\":".utf8)
        bytes.append(try encoder.encode(method))
        if let id { bytes.append(Data(",\"id\":".utf8)); bytes.append(try encoder.encode(id)) }
        bytes.append(Data(",\"params\":".utf8)); bytes.append(params); bytes.append(125)
        guard !bytes.contains(10), !bytes.contains(13) else { throw MCPWireError.malformedMessage }
        return try MCPMessage(bytes: bytes)
    }
    private struct Envelope: Decodable {
        let id: MCPRequestID?
        let kind: Kind
        enum Keys: String, CodingKey { case jsonrpc, id, method, params, result, error }
        struct Object: Decodable {
            struct Key: CodingKey { let stringValue: String; let intValue: Int? = nil; init?(stringValue: String) { self.stringValue = stringValue }; init?(intValue: Int) { return nil } }
            init(from decoder: any Decoder) throws { _ = try decoder.container(keyedBy: Key.self) }
        }
        struct Failure: Decodable { let code: Int; let message: String }
        init(from decoder: any Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            guard try c.decode(String.self, forKey: .jsonrpc) == "2.0" else { throw MCPWireError.malformedMessage }
            id = c.contains(.id) ? try c.decode(MCPRequestID.self, forKey: .id) : nil
            if c.contains(.method) {
                guard !c.contains(.result), !c.contains(.error) else { throw MCPWireError.malformedMessage }
                let method = try c.decode(String.self, forKey: .method)
                guard !method.isEmpty, method.utf8.count <= 1024,
                      !method.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw MCPWireError.malformedMessage }
                if c.contains(.params) { _ = try c.decode(Object.self, forKey: .params) }
                kind = id == nil ? .notification(method) : .request(method)
            } else {
                guard !c.contains(.params), c.contains(.result) != c.contains(.error) else { throw MCPWireError.malformedMessage }
                if c.contains(.result) {
                    guard id != nil else { throw MCPWireError.malformedMessage }
                    _ = try c.decode(Object.self, forKey: .result); kind = .result
                } else {
                    let failure = try c.decode(Failure.self, forKey: .error)
                    kind = .error(failure.code)
                }
            }
        }
    }
}
