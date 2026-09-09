import Foundation

enum CodexWireError: Error, Equatable, Sendable {
    case malformedMessage, recordLimit, unexpectedResponse, scopeMismatch, rejectedConfiguration, incompleteTurn
}

/// Incremental JSONL framing. UTF-8 is validated only for a complete record, never per pipe chunk.
struct CodexJSONLineFramer: Sendable {
    private var pending = Data()
    private var count = 0
    private var ended = false
    private let maximumRecordBytes: Int
    init(maximumRecordBytes: Int = 262_144) throws {
        guard (1...1_048_576).contains(maximumRecordBytes) else { throw CodexWireError.recordLimit }
        self.maximumRecordBytes = maximumRecordBytes
    }
    mutating func append(_ bytes: Data) throws -> [Data] {
        guard !ended, bytes.count <= 1_048_576 else { throw CodexWireError.recordLimit }
        var records: [Data] = []
        for byte in bytes {
            if byte == 10 {
                if let line = try record() { records.append(line) }
            } else {
                guard pending.count < maximumRecordBytes else { throw CodexWireError.recordLimit }
                pending.append(byte)
            }
        }
        return records
    }
    mutating func finish() throws -> [Data] {
        guard !ended else { throw CodexWireError.unexpectedResponse }
        ended = true
        return try record().map { [$0] } ?? []
    }
    private mutating func record() throws -> Data? {
        if pending.last == 13 { pending.removeLast() }
        guard !pending.isEmpty else { return nil }
        guard count < 10_000, String(data: pending, encoding: .utf8) != nil else { throw CodexWireError.malformedMessage }
        count += 1
        let result = pending; pending = Data()
        return result
    }
}

/// Narrow Codable wire value; no Foundation Any crosses actors and deeply nested input fails closed.
enum CodexJSONValue: Codable, Sendable, Equatable {
    case object([String: CodexJSONValue]), array([CodexJSONValue]), string(String), integer(Int64), number(Double), bool(Bool), null
    var object: [String: CodexJSONValue]? { if case .object(let value) = self { value } else { nil } }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var integer: Int64? { if case .integer(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var array: [CodexJSONValue]? { if case .array(let value) = self { value } else { nil } }
    subscript(_ key: String) -> CodexJSONValue? { object?[key] }

    init(from decoder: any Decoder) throws {
        guard decoder.codingPath.count <= 32 else { throw CodexWireError.malformedMessage }
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let item = try? value.decode(Bool.self) { self = .bool(item) }
        else if let item = try? value.decode(Int64.self) { self = .integer(item) }
        else if let item = try? value.decode(Double.self), item.isFinite { self = .number(item) }
        else if let item = try? value.decode(String.self) { self = .string(item) }
        else if let item = try? value.decode([CodexJSONValue].self) { self = .array(item) }
        else if let item = try? value.decode([String: CodexJSONValue].self) { self = .object(item) }
        else { throw CodexWireError.malformedMessage }
    }
    func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .bool(let item): try value.encode(item)
        case .integer(let item): try value.encode(item)
        case .number(let item): try value.encode(item)
        case .string(let item): try value.encode(item)
        case .array(let item): try value.encode(item)
        case .object(let item): try value.encode(item)
        }
    }
    static func decodeMessage(_ bytes: Data) throws -> [String: CodexJSONValue] {
        guard bytes.count <= 262_144 else { throw CodexWireError.recordLimit }
        guard !bytes.contains(0), String(data: bytes, encoding: .utf8) != nil else { throw CodexWireError.malformedMessage }
        do {
            let value = try JSONDecoder().decode(Self.self, from: bytes)
            guard let object = value.object else { throw CodexWireError.malformedMessage }
            return object
        } catch { throw CodexWireError.malformedMessage }
    }
    func line() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(self)
        guard data.count <= 262_144 else { throw CodexWireError.recordLimit }
        data.append(10); return data
    }
}
