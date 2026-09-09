import Foundation

/// Token-range sanitizer: validates JSON without converting numbers or rewriting unrelated source bytes.
struct SensitiveJSONScanner {
    private let bytes: [UInt8]
    private let sensitiveField: (String) -> Bool
    private let privateString: (String) throws -> Bool
    private var index = 0
    private var nodes = 0
    private var ranges: [Range<Int>] = []
    init(input: String, sensitiveField: @escaping (String) -> Bool, privateString: @escaping (String) throws -> Bool) {
        bytes = Array(input.utf8); self.sensitiveField = sensitiveField; self.privateString = privateString
    }
    mutating func redacted() throws -> (String, Int) {
        _ = try value(depth: 0, masked: false)
        whitespace()
        guard index == bytes.count else { throw RedactionError.invalidContent }
        var output = Data(), next = 0
        for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            guard range.lowerBound >= next else { throw RedactionError.invalidContent }
            output.append(contentsOf: bytes[next..<range.lowerBound]); output.append(contentsOf: #""[REDACTED]""#.utf8)
            next = range.upperBound
        }
        output.append(contentsOf: bytes[next..<bytes.count])
        return (String(decoding: output, as: UTF8.self), ranges.count)
    }
    private mutating func whitespace() { while index < bytes.count, [9, 10, 13, 32].contains(bytes[index]) { index += 1 } }
    private mutating func take(_ byte: UInt8) -> Bool {
        whitespace()
        if index < bytes.count, bytes[index] == byte { index += 1; return true }; return false
    }
    private mutating func value(depth: Int, masked: Bool) throws -> Range<Int> {
        try Task.checkCancellation(); whitespace(); nodes += 1
        guard depth <= 40, nodes <= 8_192, index < bytes.count else { throw RedactionError.invalidContent }
        let start = index
        switch bytes[index] {
        case 123:
            index += 1
            var keys = Set<String>()
            if !take(125) {
                repeat {
                    whitespace(); let key = try string()
                    guard keys.insert(key).inserted, take(58) else { throw RedactionError.invalidContent }
                    // Secret-bearing keys cannot be replaced safely without risking duplicate member identities.
                    if !masked, try privateString(key) { throw RedactionError.invalidContent }
                    let hide = sensitiveField(key)
                    let range = try value(depth: depth + 1, masked: masked || hide)
                    if hide && !masked { ranges.append(range) }
                    if take(125) { break }
                    guard take(44) else { throw RedactionError.invalidContent }
                } while true
            }
        case 91:
            index += 1
            if !take(93) {
                repeat {
                    _ = try value(depth: depth + 1, masked: masked)
                    if take(93) { break }
                    guard take(44) else { throw RedactionError.invalidContent }
                } while true
            }
        case 34:
            let text = try string()
            if !masked, try privateString(text) { ranges.append(start..<index) }
        case 116, 102, 110:
            try literal(bytes[index] == 116 ? "true" : bytes[index] == 102 ? "false" : "null")
            if !masked, try privateString(String(decoding: bytes[start..<index], as: UTF8.self)) { ranges.append(start..<index) }
        default:
            try number()
            if !masked, try privateString(String(decoding: bytes[start..<index], as: UTF8.self)) { ranges.append(start..<index) }
        }
        return start..<index
    }
    private mutating func literal(_ text: String) throws {
        let value = Array(text.utf8)
        guard index + value.count <= bytes.count, bytes[index..<index + value.count].elementsEqual(value) else { throw RedactionError.invalidContent }
        index += value.count
    }
    private mutating func string() throws -> String {
        guard index < bytes.count, bytes[index] == 34 else { throw RedactionError.invalidContent }
        let start = index; index += 1
        while index < bytes.count {
            let byte = bytes[index]; index += 1
            if byte == 92 { guard index < bytes.count else { break }; index += 1 }
            else if byte == 34 {
                guard let result = try? JSONDecoder().decode(String.self, from: Data(bytes[start..<index])) else { throw RedactionError.invalidContent }
                return result
            }
        }
        throw RedactionError.invalidContent
    }
    private mutating func number() throws {
        let start = index
        if index < bytes.count, bytes[index] == 45 { index += 1 }
        guard index < bytes.count else { throw RedactionError.invalidContent }
        if bytes[index] == 48 { index += 1 }
        else { guard (49...57).contains(bytes[index]) else { throw RedactionError.invalidContent }; digits() }
        if index < bytes.count, bytes[index] == 46 { index += 1; try requiredDigits() }
        if index < bytes.count, bytes[index] == 101 || bytes[index] == 69 {
            index += 1
            if index < bytes.count, bytes[index] == 43 || bytes[index] == 45 { index += 1 }
            try requiredDigits()
        }
        guard index - start <= 256 else { throw RedactionError.sizeLimit }
    }
    private mutating func requiredDigits() throws {
        guard index < bytes.count, (48...57).contains(bytes[index]) else { throw RedactionError.invalidContent }
        digits()
    }
    private mutating func digits() { while index < bytes.count, (48...57).contains(bytes[index]) { index += 1 } }
}
