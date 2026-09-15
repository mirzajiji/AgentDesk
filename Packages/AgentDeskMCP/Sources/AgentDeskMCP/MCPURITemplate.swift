import Foundation

public enum MCPURITemplateError: Error, Equatable, Sendable {
    case invalidSyntax, unsupportedOperator, sizeLimit
}

/// Parsed RFC 6570 syntax only. Parsing neither expands values nor grants resource access.
public struct MCPURITemplate: Sendable {
    public let source: String
    public let variableNames: [String]
    struct Variable: Sendable {
        let name: String
        let prefix: Int?
        let explode: Bool
    }
    enum Segment: Sendable {
        case literal(String)
        case expression(Character?, [Variable])
    }
    let segments: [Segment]

    public init(_ source: String) throws {
        try Task.checkCancellation()
        guard source.utf8.count <= 4096 else { throw MCPURITemplateError.sizeLimit }
        let scalars = Array(source.unicodeScalars)
        var index = 0, literal = "", segments: [Segment] = [], names: [String] = []
        var seen = Set<String>(), expressions = 0, variables = 0
        while index < scalars.count {
            try Task.checkCancellation()
            let scalar = scalars[index]
            if scalar == "{" {
                if !literal.isEmpty { segments.append(.literal(literal)); literal = "" }
                index += 1; let start = index
                while index < scalars.count, scalars[index] != "}" { index += 1 }
                guard index < scalars.count else { throw MCPURITemplateError.invalidSyntax }
                var expression = String(String.UnicodeScalarView(scalars[start..<index]))
                index += 1; expressions += 1
                guard expressions <= 128 else { throw MCPURITemplateError.sizeLimit }
                var operation: Character?
                if let first = expression.first, "=,!@|".contains(first) { throw MCPURITemplateError.unsupportedOperator }
                if let first = expression.first, "+#./;?&".contains(first) { operation = first; expression.removeFirst() }
                var parsed: [Variable] = []
                for field in expression.split(separator: ",", omittingEmptySubsequences: false) {
                    var name = String(field), prefix: Int?, explode = false
                    if name.hasSuffix("*") { explode = true; name.removeLast() }
                    if let colon = name.firstIndex(of: ":") {
                        let length = String(name[name.index(after: colon)...])
                        guard !explode, length.range(of: #"^[1-9][0-9]{0,3}\z"#, options: .regularExpression) != nil,
                              let value = Int(length) else { throw MCPURITemplateError.invalidSyntax }
                        prefix = value; name = String(name[..<colon])
                    }
                    guard name.range(of: #"^(?:[A-Za-z0-9_]|%[0-9A-Fa-f]{2})(?:\.?(?:[A-Za-z0-9_]|%[0-9A-Fa-f]{2}))*\z"#,
                                     options: .regularExpression) != nil else { throw MCPURITemplateError.invalidSyntax }
                    variables += 1
                    guard variables <= 256 else { throw MCPURITemplateError.sizeLimit }
                    parsed.append(Variable(name: name, prefix: prefix, explode: explode))
                    if seen.insert(name).inserted { names.append(name) }
                }
                segments.append(.expression(operation, parsed))
            } else if scalar == "%" {
                guard index + 2 < scalars.count, Self.hex(scalars[index + 1]), Self.hex(scalars[index + 2]) else {
                    throw MCPURITemplateError.invalidSyntax
                }
                literal.unicodeScalars.append(contentsOf: scalars[index...index + 2]); index += 3
            } else {
                guard Self.literal(scalar.value) else { throw MCPURITemplateError.invalidSyntax }
                literal.unicodeScalars.append(scalar); index += 1
            }
        }
        if !literal.isEmpty { segments.append(.literal(literal)) }
        try Task.checkCancellation()
        self.source = source; self.variableNames = names; self.segments = segments
    }
    private static func hex(_ scalar: Unicode.Scalar) -> Bool {
        (48...57).contains(scalar.value) || (65...70).contains(scalar.value) || (97...102).contains(scalar.value)
    }
    private static func literal(_ value: UInt32) -> Bool {
        if value < 128 {
            return value == 0x21 || (0x23...0x24).contains(value) || value == 0x26 || (0x28...0x3B).contains(value)
                || value == 0x3D || (0x3F...0x5B).contains(value) || value == 0x5D || value == 0x5F
                || (0x61...0x7A).contains(value) || value == 0x7E
        }
        return (0xA0...0xD7FF).contains(value) || (0xE000...0xF8FF).contains(value)
            || (0xF900...0xFDCF).contains(value) || (0xFDF0...0xFFEF).contains(value)
            || ((0x10000...0xDFFFD).contains(value) && value & 0xFFFF <= 0xFFFD)
            || (0xE1000...0xEFFFD).contains(value)
            || (0xF0000...0xFFFFD).contains(value) || (0x100000...0x10FFFD).contains(value)
    }
}
