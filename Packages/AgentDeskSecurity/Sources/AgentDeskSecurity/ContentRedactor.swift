import AgentDeskCore
import Foundation

public struct RedactionContext: Codable, Hashable, Sendable {
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let runID: RunID
    public init(scope: ProjectScope, environmentID: EnvironmentID, runID: RunID) {
        self.scope = scope; self.environmentID = environmentID; self.runID = runID
    }
    func permits(_ secret: SecretReference) -> Bool {
        secret.scope.workspaceID == scope.workspaceID && (secret.scope.projectID == nil || secret.scope.projectID == scope.projectID)
            && (secret.scope.environmentID == nil || secret.scope.environmentID == environmentID)
    }
}
public enum EvidenceClassification: String, Codable, Sendable { case publicData = "public", internalData = "internal", confidential, secret }
public enum RedactionError: Error, Equatable, Sendable {
    case scopeMismatch, invalidPolicy, secretUnavailable, invalidContent, sizeLimit, secretClassification, streamFinished
}
/// Only the redactor can create this value. Decoding arbitrary JSON cannot assert that text is safe.
/// It remains scoped evidence, not a grant to export or display it to a different principal.
public struct RedactedText: Encodable, Equatable, Sendable {
    public let context: RedactionContext
    public let text: String
    public let classification: EvidenceClassification
    public let redactionCount: Int
    public let policyVersion: Int
    fileprivate init(context: RedactionContext, text: String, classification: EvidenceClassification, count: Int) {
        self.context = context; self.text = text; self.classification = classification; redactionCount = count; policyVersion = 1
    }
}
/// Scoped, deterministic defense in depth. Known values never appear in diagnostics or Codable output.
public struct ContentRedactor: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let context: RedactionContext
    private let variants: [String]
    private let secretBytes: [Data]
    private let fields: Set<String>
    private let fieldPatterns: [String]
    private static let defaults = ["password", "passwd", "pwd", "secret", "token", "apiKey", "accessToken", "refreshToken",
                                   "clientSecret", "authorization", "proxyAuthorization", "cookie", "setCookie", "privateKey", "connectionString", "xApiKey"]
    public var description: String { "<scoped redaction policy>" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: ["policy": description]) }

    public init(context: RedactionContext, sensitiveFields: [String] = []) throws {
        try self.init(context: context, sensitiveFields: sensitiveFields, secrets: [])
    }
    private init(context: RedactionContext, sensitiveFields: [String], secrets: [SecretValue]) throws {
        guard sensitiveFields.count <= 64, secrets.count <= 64 else { throw RedactionError.invalidPolicy }
        let names = Self.defaults + sensitiveFields
        guard names.allSatisfy({ !Self.normalizedField($0).isEmpty && $0.utf8.count <= 64 && $0.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "_- ".unicodeScalars.contains($0) } }) else { throw RedactionError.invalidPolicy }
        self.context = context
        fields = Set(names.map(Self.normalizedField))
        fieldPatterns = Array(fields).sorted().map { $0.map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: "[ _-]?") }
        var values = Set<String>(), bytes = 0, rawValues: [Data] = []
        for secret in secrets {
            try Task.checkCancellation()
            try secret.withBytes { data in
                bytes += data.count
                guard bytes <= 65_536 else { throw RedactionError.invalidPolicy }
                rawValues.append(data)
                values.insert(data.base64EncodedString())
                values.insert(data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: ""))
                values.insert(data.map { String(format: "%02x", $0) }.joined())
                values.insert(data.map { String(format: "%02X", $0) }.joined())
                values.insert(data.map { String(format: "%%%02X", $0) }.joined())
                values.insert(data.map { String(format: "%%%02x", $0) }.joined())
                if let text = String(data: data, encoding: .utf8) {
                    values.insert(text)
                    let encoded = String(decoding: try JSONEncoder().encode(text), as: UTF8.self)
                    let escaped = String(encoded.dropFirst().dropLast())
                    values.insert(escaped); values.insert(escaped.replacingOccurrences(of: "/", with: "\\/"))
                    values.insert(text.utf16.map { String(format: "\\u%04x", $0) }.joined())
                    values.insert(text.utf16.map { String(format: "\\u%04X", $0) }.joined())
                    let unreserved = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")
                    if let encoded = text.addingPercentEncoding(withAllowedCharacters: unreserved) { values.insert(encoded) }
                }
            }
        }
        values.remove("")
        guard values.count <= 1_024, values.reduce(0, { $0 + $1.utf8.count }) <= 4_194_304 else { throw RedactionError.invalidPolicy }
        variants = values.sorted { $0.utf8.count == $1.utf8.count ? $0 < $1 : $0.utf8.count > $1.utf8.count }
        secretBytes = rawValues
    }
    /// Resolve only deliberately supplied scoped references. Missing/failed secrets prevent policy creation.
    /// The injected resolver remains responsible for authorizing Keychain access.
    public static func load(context: RedactionContext, sensitiveFields: [String] = [], references: [SecretReference],
                            resolve: @Sendable (SecretReference) async throws -> SecretValue?) async throws -> ContentRedactor {
        try Task.checkCancellation()
        guard references.count <= 64, Set(references).count == references.count else { throw RedactionError.invalidPolicy }
        guard references.allSatisfy(context.permits) else { throw RedactionError.scopeMismatch }
        var secrets: [SecretValue] = []
        for reference in references {
            try Task.checkCancellation()
            do {
                guard let value = try await resolve(reference) else { throw RedactionError.secretUnavailable }
                secrets.append(value)
            } catch is CancellationError { throw CancellationError() }
            catch { throw RedactionError.secretUnavailable }
        }
        return try ContentRedactor(context: context, sensitiveFields: sensitiveFields, secrets: secrets)
    }
    public func redactText(_ input: String, in requested: RedactionContext,
                           classification: EvidenceClassification = .internalData) throws -> RedactedText {
        try validate(input, requested: requested, classification: classification)
        let ranges = try privateRanges(input)
        let result = NSMutableString(string: input)
        for range in ranges.reversed() { result.replaceCharacters(in: range, with: "[REDACTED]") }
        return try output(result as String, classification: classification, count: ranges.count)
    }
    /// Preserves all unredacted source bytes, including numeric spelling/precision and whitespace.
    /// Sensitive fields mask their complete value; sensitive string values mask the complete string.
    public func redactJSON(_ input: String, in requested: RedactionContext,
                           classification: EvidenceClassification = .internalData) throws -> RedactedText {
        try validate(input, requested: requested, classification: classification)
        var scanner = SensitiveJSONScanner(input: input, sensitiveField: { self.fields.contains(Self.normalizedField($0)) },
                                           privateString: { try !self.privateRanges($0).isEmpty })
        let (text, count) = try scanner.redacted()
        return try output(text, classification: classification, count: count)
    }
    private func validate(_ input: String, requested: RedactionContext, classification: EvidenceClassification) throws {
        try Task.checkCancellation()
        guard requested == context else { throw RedactionError.scopeMismatch }
        guard classification != .secret else { throw RedactionError.secretClassification }
        guard input.utf8.count <= 262_144, !input.utf8.contains(0) else { throw RedactionError.sizeLimit }
    }
    private func output(_ text: String, classification: EvidenceClassification, count: Int) throws -> RedactedText {
        try Task.checkCancellation()
        guard text.utf8.count <= 1_048_576 else { throw RedactionError.sizeLimit }
        return RedactedText(context: context, text: text, classification: count > 0 ? .confidential : classification, count: count)
    }
    private func privateRanges(_ text: String) throws -> [NSRange] {
        let full = NSRange(location: 0, length: (text as NSString).length)
        var ranges: [NSRange] = []
        let source = text as NSString
        for value in variants {
            try Task.checkCancellation()
            var remaining = full
            while remaining.length > 0 {
                let match = source.range(of: value, options: .literal, range: remaining)
                if match.location == NSNotFound { break }
                ranges.append(match)
                let next = match.location + 1; remaining = NSRange(location: next, length: full.length - next)
                guard ranges.count <= 65_536 else { throw RedactionError.sizeLimit }
            }
        }
        ranges += try PercentEncodedSecrets.ranges(in: text, secrets: secretBytes)
        let names = fieldPatterns.joined(separator: "|")
        let patterns = [
            #"(?im)(?<![\p{L}\p{N}_-])(?:[\"']?(?:"# + names + #")[\"']?\s*[:=]\s*)(\"(?:\\.|[^\"\\])*\"|'(?:\\.|[^'\\])*'|[^\r\n,;]+)"#,
            #"(?im)\b(?:authorization|proxy[ _-]?authorization|cookie|set[ _-]?cookie)\s*[:=]\s*[^\r\n]*"#,
            #"(?is)-----BEGIN (?:[A-Z0-9 ]* )?PRIVATE KEY-----.*?(?:-----END (?:[A-Z0-9 ]* )?PRIVATE KEY-----|\z)"#,
            #"(?i)\b(?:postgres(?:ql)?|mysql|mongodb(?:\+srv)?|redis|https?)://[^\s/@:]+:[^\s/@]+@[^\s\"'<>]*"#,
            #"\b(?:gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|glpat-[A-Za-z0-9_-]{16,}|sk-(?:proj-)?[A-Za-z0-9_-]{20,})\b"#,
            #"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b"#
        ]
        for (index, pattern) in patterns.enumerated() {
            try Task.checkCancellation()
            guard let expression = try? NSRegularExpression(pattern: pattern) else { throw RedactionError.invalidPolicy }
            for match in expression.matches(in: text, range: full) {
                let range = index == 0 ? match.range(at: 1) : match.range
                if range.length > 0 { ranges.append(range) }
            }
        }
        let sorted = ranges.sorted { $0.location == $1.location ? $0.length > $1.length : $0.location < $1.location }
        var merged: [NSRange] = []
        for range in sorted {
            if let last = merged.last, range.location <= NSMaxRange(last) {
                merged[merged.count - 1] = NSRange(location: last.location, length: max(NSMaxRange(last), NSMaxRange(range)) - last.location)
            } else { merged.append(range) }
        }
        return merged
    }
    private static func normalizedField(_ value: String) -> String {
        value.lowercased().filter { $0 != "_" && $0 != "-" && $0 != " " }
    }
}
