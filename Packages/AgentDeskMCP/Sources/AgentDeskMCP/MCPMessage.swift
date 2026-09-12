import AgentDeskCore
import Foundation

public enum MCPWireError: Error, Equatable, Sendable {
    case malformedMessage, messageTooLarge, invalidLimit, streamClosed, truncatedMessage
}

public enum MCPRequestID: Hashable, Sendable, Decodable {
    case string(String), integer(Int64)
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
