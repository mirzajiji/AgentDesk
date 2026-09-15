import Foundation

public enum MCPURITemplateValue: Sendable {
    case string(String), list([String]), associative([String: String])
}

extension MCPURITemplate {
    /// Returns an untrusted URI reference. The host must validate and authorize the final URI separately.
    public func expand(_ values: [String: MCPURITemplateValue]) throws -> String {
        try Task.checkCancellation()
        guard values.count <= 256 else { throw MCPURITemplateError.sizeLimit }
        var bytes = 0, items = 0
        for (name, value) in values {
            try Task.checkCancellation()
            bytes += name.utf8.count
            guard bytes <= 65_536 else { throw MCPURITemplateError.sizeLimit }
            let strings: [String]
            switch value {
            case .string(let text): strings = [text]
            case .list(let list):
                guard list.count <= 1024 else { throw MCPURITemplateError.sizeLimit }
                strings = list
            case .associative(let map):
                guard map.count <= 512 else { throw MCPURITemplateError.sizeLimit }
                strings = map.flatMap { [$0.key, $0.value] }
            }
            items += strings.count
            guard items <= 1024 else { throw MCPURITemplateError.sizeLimit }
            for text in strings {
                bytes += text.utf8.count
                guard bytes <= 65_536 else { throw MCPURITemplateError.sizeLimit }
            }
        }
        var output = ""
        for segment in segments {
            try Task.checkCancellation()
            switch segment {
            case .literal(let text): output += Self.encode(text, reserved: true)
            case .expression(let op, let variables):
                let reserved = op == "+" || op == "#"
                let named = op == ";" || op == "?" || op == "&"
                let first = op == nil || op == "+" ? "" : String(op!)
                let separator = op == "/" || op == "." || op == ";" ? String(op!) : (op == "?" || op == "&" ? "&" : ",")
                func encode(_ value: String) -> String { Self.encode(value, reserved: reserved) }
                func namedPart(_ name: String, _ value: String) -> String {
                    named ? name + (value.isEmpty && op == ";" ? "" : "=" + value) : value
                }
                var parts: [String] = []
                for variable in variables {
                    try Task.checkCancellation()
                    guard let value = values[variable.name] else { continue }
                    let name = Self.encode(variable.name, reserved: true)
                    switch value {
                    case .string(let text):
                        let selected = variable.prefix.map { Self.prefix(text, count: $0) } ?? text
                        parts.append(namedPart(name, encode(selected)))
                    case .list(let list):
                        guard variable.prefix == nil else { throw MCPURITemplateError.invalidSyntax }
                        guard !list.isEmpty else { continue }
                        if variable.explode { parts += list.map { namedPart(name, encode($0)) } }
                        else { parts.append(namedPart(name, list.map(encode).joined(separator: ","))) }
                    case .associative(let map):
                        guard variable.prefix == nil else { throw MCPURITemplateError.invalidSyntax }
                        guard !map.isEmpty else { continue }
                        let pairs = map.sorted { $0.key < $1.key }
                        if variable.explode {
                            parts += pairs.map { key, value in
                                let key = encode(key), value = encode(value)
                                return key + (value.isEmpty && op == ";" ? "" : "=" + value)
                            }
                        } else { parts.append(namedPart(name, pairs.flatMap { [encode($0.key), encode($0.value)] }.joined(separator: ","))) }
                    }
                }
                if !parts.isEmpty { output += first + parts.joined(separator: separator) }
            }
            guard output.utf8.count <= 65_536 else { throw MCPURITemplateError.sizeLimit }
        }
        try Task.checkCancellation()
        return output
    }
    private static func encode(_ text: String, reserved: Bool) -> String {
        let bytes = Array(text.utf8), hex = Array("0123456789ABCDEF".utf8)
        let extra = Set(":/?#[]@!$&'()*+,;=".utf8)
        var result: [UInt8] = [], index = 0
        while index < bytes.count {
            let b = bytes[index]
            if reserved, b == 37, index + 2 < bytes.count,
               isHex(bytes[index + 1]), isHex(bytes[index + 2]) {
                result.append(contentsOf: bytes[index...index + 2]); index += 3; continue
            }
            if (65...90).contains(b) || (97...122).contains(b) || (48...57).contains(b)
                || [45, 46, 95, 126].contains(b) || (reserved && extra.contains(b)) { result.append(b) }
            else { result.append(contentsOf: [37, hex[Int(b >> 4)], hex[Int(b & 15)]]) }
            index += 1
        }
        return String(decoding: result, as: UTF8.self)
    }
    private static func isHex(_ b: UInt8) -> Bool {
        (48...57).contains(b) || (65...70).contains(b) || (97...102).contains(b)
    }
    /// Count Unicode code points without cutting a percent-encoded UTF-8 scalar.
    private static func prefix(_ text: String, count: Int) -> String {
        let scalars = Array(text.unicodeScalars)
        var index = 0, used = 0, result = ""
        while index < scalars.count, used < count {
            var length = 1
            if scalars[index] == "%" {
                var encoded: [UInt8] = [], end = index
                while end + 2 < scalars.count, scalars[end] == "%", encoded.count < 4,
                      let byte = UInt8(String(String.UnicodeScalarView(scalars[end + 1...end + 2])), radix: 16) {
                    encoded.append(byte); end += 3
                    if let decoded = String(bytes: encoded, encoding: .utf8), decoded.unicodeScalars.count == 1 {
                        length = end - index; break
                    }
                }
            }
            result.unicodeScalars.append(contentsOf: scalars[index..<index + length])
            index += length; used += 1
        }
        return result
    }
}
