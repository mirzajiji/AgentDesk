import Foundation

public enum OutputContractError: Error, Equatable, Sendable {
    case invalidSchema, invalidJSON, mismatch, sizeLimit
}

/// Deliberately small JSON Schema subset, compatible with strict structured output:
/// closed objects with required properties, bounded arrays/strings, 32-bit integers, booleans and null.
public indirect enum OutputSchema: Equatable, Sendable, Codable {
    case object([String: OutputSchema])
    case array(items: OutputSchema, minimum: Int, maximum: Int)
    case string(minimum: Int, maximum: Int, choices: [String]?)
    case integer(minimum: Int, maximum: Int)
    case boolean
    case null

    public func validate() throws {
        var nodes = 0
        try validate(depth: 0, nodes: &nodes)
    }
    private func validate(depth: Int, nodes: inout Int) throws {
        nodes += 1
        guard depth <= 12, nodes <= 256 else { throw OutputContractError.invalidSchema }
        switch self {
        case .object(let fields):
            guard fields.count <= 64 else { throw OutputContractError.invalidSchema }
            for (key, value) in fields {
                guard !key.isEmpty, key.utf8.count <= 64,
                      key.utf8.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 95 || $0 == 45 }) else {
                    throw OutputContractError.invalidSchema
                }
                try value.validate(depth: depth + 1, nodes: &nodes)
            }
        case .array(let items, let minimum, let maximum):
            guard minimum >= 0, maximum >= minimum, maximum <= 1_000 else { throw OutputContractError.invalidSchema }
            try items.validate(depth: depth + 1, nodes: &nodes)
        case .string(let minimum, let maximum, let choices):
            guard minimum >= 0, maximum >= minimum, maximum <= 65_536 else { throw OutputContractError.invalidSchema }
            if let choices {
                guard !choices.isEmpty, choices.count <= 64, Set(choices).count == choices.count,
                      choices.allSatisfy({ $0.unicodeScalars.count >= minimum && $0.unicodeScalars.count <= maximum && !$0.utf8.contains(0) }) else {
                    throw OutputContractError.invalidSchema
                }
            }
        case .integer(let minimum, let maximum):
            guard minimum >= Int(Int32.min), maximum <= Int(Int32.max), minimum <= maximum else { throw OutputContractError.invalidSchema }
        case .boolean, .null: break
        }
    }

    public func jsonData() throws -> Data {
        try validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(self)
        guard data.count <= 65_536 else { throw OutputContractError.invalidSchema }
        return data
    }
    public init(jsonData: Data) throws {
        guard jsonData.count <= 65_536 else { throw OutputContractError.invalidSchema }
        do {
            _ = try OutputJSON.parse(jsonData)
            self = try JSONDecoder().decode(Self.self, from: jsonData)
            try validate()
        } catch is CancellationError { throw CancellationError() }
        catch { throw OutputContractError.invalidSchema }
    }
    public func validateOutput(_ text: String, maximumBytes: Int = 262_144) throws {
        try validate()
        guard (1...262_144).contains(maximumBytes), text.utf8.count <= maximumBytes else { throw OutputContractError.sizeLimit }
        try matches(OutputJSON.parse(Data(text.utf8)))
    }
    private func matches(_ value: OutputJSON) throws {
        switch (self, value) {
        case (.object(let fields), .object(let values)):
            guard Set(fields.keys) == Set(values.keys) else { throw OutputContractError.mismatch }
            for (key, schema) in fields { try schema.matches(values[key]!) }
        case (.array(let schema, let minimum, let maximum), .array(let values)):
            guard (minimum...maximum).contains(values.count) else { throw OutputContractError.mismatch }
            for value in values { try schema.matches(value) }
        case (.string(let minimum, let maximum, let choices), .string(let value)):
            guard (minimum...maximum).contains(value.unicodeScalars.count), !value.utf8.contains(0),
                  choices == nil || choices!.contains(where: { $0.unicodeScalars.elementsEqual(value.unicodeScalars) }) else { throw OutputContractError.mismatch }
        case (.integer(let minimum, let maximum), .number(let number)):
            var number = number, rounded = Decimal()
            NSDecimalRound(&rounded, &number, 0, .plain)
            guard number == rounded, number >= Decimal(minimum), number <= Decimal(maximum) else { throw OutputContractError.mismatch }
        case (.boolean, .bool), (.null, .null): break
        default: throw OutputContractError.mismatch
        }
    }

    private struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { stringValue = value }
        init?(stringValue: String) { self.init(stringValue) }
        init?(intValue: Int) { return nil }
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: Key.self)
        let type = try values.decode(String.self, forKey: Key("type"))
        let permitted: Set<String>
        switch type {
        case "object":
            permitted = ["type", "properties", "required", "additionalProperties"]
            let fields = try values.decode([String: Self].self, forKey: Key("properties"))
            let required = try values.decode([String].self, forKey: Key("required"))
            guard try values.decode(Bool.self, forKey: Key("additionalProperties")) == false,
                  Set(required) == Set(fields.keys), required.count == fields.count else { throw OutputContractError.invalidSchema }
            self = .object(fields)
        case "array":
            permitted = ["type", "items", "minItems", "maxItems"]
            self = try .array(items: values.decode(Self.self, forKey: Key("items")), minimum: values.decode(Int.self, forKey: Key("minItems")), maximum: values.decode(Int.self, forKey: Key("maxItems")))
        case "string":
            permitted = ["type", "minLength", "maxLength", "enum"]
            self = try .string(minimum: values.decode(Int.self, forKey: Key("minLength")), maximum: values.decode(Int.self, forKey: Key("maxLength")), choices: values.contains(Key("enum")) ? values.decode([String].self, forKey: Key("enum")) : nil)
        case "integer":
            permitted = ["type", "minimum", "maximum"]
            self = try .integer(minimum: values.decode(Int.self, forKey: Key("minimum")), maximum: values.decode(Int.self, forKey: Key("maximum")))
        case "boolean": permitted = ["type"]; self = .boolean
        case "null": permitted = ["type"]; self = .null
        default: throw OutputContractError.invalidSchema
        }
        guard Set(values.allKeys.map(\.stringValue)).isSubset(of: permitted) else { throw OutputContractError.invalidSchema }
        try validate()
    }
    public func encode(to encoder: any Encoder) throws {
        try validate()
        var values = encoder.container(keyedBy: Key.self)
        func key(_ value: String) -> Key { Key(value) }
        switch self {
        case .object(let fields):
            try values.encode("object", forKey: key("type")); try values.encode(fields, forKey: key("properties"))
            try values.encode(fields.keys.sorted(), forKey: key("required")); try values.encode(false, forKey: key("additionalProperties"))
        case .array(let items, let minimum, let maximum):
            try values.encode("array", forKey: key("type")); try values.encode(items, forKey: key("items"))
            try values.encode(minimum, forKey: key("minItems")); try values.encode(maximum, forKey: key("maxItems"))
        case .string(let minimum, let maximum, let choices):
            try values.encode("string", forKey: key("type")); try values.encode(minimum, forKey: key("minLength"))
            try values.encode(maximum, forKey: key("maxLength")); try values.encodeIfPresent(choices, forKey: key("enum"))
        case .integer(let minimum, let maximum):
            try values.encode("integer", forKey: key("type")); try values.encode(minimum, forKey: key("minimum")); try values.encode(maximum, forKey: key("maximum"))
        case .boolean: try values.encode("boolean", forKey: key("type"))
        case .null: try values.encode("null", forKey: key("type"))
        }
    }
}

/// Strict, resource-bounded JSON reader. Rejects duplicate keys and lossy/out-of-range decimals.
/// Errors never contain untrusted output or schema content.
indirect enum OutputJSON {
    case object([String: OutputJSON]), array([OutputJSON]), string(String), number(Decimal), bool(Bool), null
    static func parse(_ data: Data) throws -> OutputJSON {
        guard data.count <= 262_144, String(data: data, encoding: .utf8) != nil else { throw OutputContractError.invalidJSON }
        var reader = Reader(bytes: Array(data))
        let value = try reader.value(depth: 0)
        reader.whitespace()
        guard reader.index == reader.bytes.count else { throw OutputContractError.invalidJSON }
        return value
    }
    private struct Reader {
        let bytes: [UInt8]
        var index = 0
        var nodes = 0
        mutating func whitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
        mutating func take(_ byte: UInt8) -> Bool {
            whitespace()
            if index < bytes.count, bytes[index] == byte { index += 1; return true }; return false
        }
        mutating func value(depth: Int) throws -> OutputJSON {
            try Task.checkCancellation()
            nodes += 1; whitespace()
            guard depth <= 40, nodes <= 8_192, index < bytes.count else { throw OutputContractError.invalidJSON }
            switch bytes[index] {
            case 123:
                index += 1; var fields: [String: OutputJSON] = [:]
                if take(125) { return .object(fields) }
                repeat {
                    whitespace(); let name = try string()
                    guard fields[name] == nil, take(58) else { throw OutputContractError.invalidJSON }
                    fields[name] = try value(depth: depth + 1)
                    if take(125) { return .object(fields) }
                    guard take(44) else { throw OutputContractError.invalidJSON }
                } while true
            case 91:
                index += 1; var items: [OutputJSON] = []
                if take(93) { return .array(items) }
                repeat {
                    items.append(try value(depth: depth + 1))
                    if take(93) { return .array(items) }
                    guard take(44) else { throw OutputContractError.invalidJSON }
                } while true
            case 34: return try .string(string())
            case 116: try literal("true"); return .bool(true)
            case 102: try literal("false"); return .bool(false)
            case 110: try literal("null"); return .null
            default:
                let start = index
                while index < bytes.count, ![9, 10, 13, 32, 44, 93, 125].contains(bytes[index]) { index += 1 }
                let token = Data(bytes[start..<index])
                // JSONDecoder checks lexical JSON number syntax; Decimal handles integer fractions exactly.
                guard token.count <= 64, bytes[start..<index].filter({ (48...57).contains($0) }).count <= 28,
                      let number = try? JSONDecoder().decode(Decimal.self, from: token), !number.isNaN else { throw OutputContractError.invalidJSON }
                return .number(number)
            }
        }
        mutating func literal(_ value: String) throws {
            let expected = Array(value.utf8)
            guard index + expected.count <= bytes.count, bytes[index..<index + expected.count].elementsEqual(expected) else { throw OutputContractError.invalidJSON }
            index += expected.count
        }
        mutating func string() throws -> String {
            guard index < bytes.count, bytes[index] == 34 else { throw OutputContractError.invalidJSON }
            let start = index; index += 1
            while index < bytes.count {
                let byte = bytes[index]; index += 1
                if byte == 92 { guard index < bytes.count else { break }; index += 1 }
                else if byte == 34 {
                    guard let result = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw OutputContractError.invalidJSON }
                    return result
                }
            }
            throw OutputContractError.invalidJSON
        }
    }
}
