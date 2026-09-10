import Foundation

public enum RequirementError: Error, Equatable, Sendable {
    case invalidDocument, invalidReview, staleVersion, scopeMismatch, limitExceeded
}

/// A stable readable identifier, never an arbitrary relative path.
public struct RequirementID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String
    public init?(rawValue: String) {
        guard (1...96).contains(rawValue.utf8.count), rawValue.first != "-", rawValue.last != "-",
              rawValue.utf8.allSatisfy({ (97...122).contains($0) || (48...57).contains($0) || $0 == 45 }) else { return nil }
        self.rawValue = rawValue
    }
    public var description: String { rawValue }
    public init(from decoder: any Decoder) throws {
        guard let value = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) else { throw RequirementError.invalidDocument }
        self = value
    }
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer(); try container.encode(rawValue)
    }
}

/// Structured expected behavior without opaque encoded JSON strings or executable expressions.
public indirect enum KnowledgeValue: Codable, Equatable, Sendable {
    case null, boolean(Bool), number(Decimal), text(String), array([KnowledgeValue]), object([String: KnowledgeValue])
    public init(from decoder: any Decoder) throws {
        let value = try decoder.singleValueContainer()
        if value.decodeNil() { self = .null }
        else if let flag = try? value.decode(Bool.self) { self = .boolean(flag) }
        else if let number = try? value.decode(Decimal.self), !number.isNaN { self = .number(number) }
        else if let text = try? value.decode(String.self) { self = .text(text) }
        else if let array = try? value.decode([KnowledgeValue].self) { self = .array(array) }
        else { self = .object(try value.decode([String: KnowledgeValue].self)) }
    }
    public func encode(to encoder: any Encoder) throws {
        var value = encoder.singleValueContainer()
        switch self {
        case .null: try value.encodeNil()
        case .boolean(let flag): try value.encode(flag)
        case .number(let number): try value.encode(number)
        case .text(let text): try value.encode(text)
        case .array(let array): try value.encode(array)
        case .object(let object): try value.encode(object)
        }
    }
    func validate(depth: Int = 0, nodes: inout Int) throws {
        nodes += 1
        guard depth <= 16, nodes <= 4_096 else { throw RequirementError.limitExceeded }
        switch self {
        case .number(let number): guard !number.isNaN else { throw RequirementError.invalidDocument }
        case .text(let text): try RequirementDraft.checkText(text, maximum: 16_384, empty: true)
        case .array(let array):
            guard array.count <= 256 else { throw RequirementError.limitExceeded }
            for item in array { try item.validate(depth: depth + 1, nodes: &nodes) }
        case .object(let object):
            guard object.count <= 256 else { throw RequirementError.limitExceeded }
            for (key, item) in object {
                try RequirementDraft.checkText(key, maximum: 256)
                try item.validate(depth: depth + 1, nodes: &nodes)
            }
        case .null, .boolean: break
        }
    }
}

public enum RequirementStatus: String, Codable, Sendable { case draft, active, retired }

public struct RequirementDraft: Codable, Equatable, Sendable {
    public var status: RequirementStatus
    public var description: String
    public var preconditions: [String]
    public var rules: [String]
    public var acceptanceCriteria: [String]
    public var validationRules: [String]
    /// Optional so legacy content retains its exact canonical encoding and historical fingerprint.
    public var executableValidationRules: [RequirementValidationRule]?
    public var expectedBehavior: [String: KnowledgeValue]
    public var environmentScope: [EnvironmentID]
    /// Source descriptions/links are inert metadata; the store never opens them.
    public var references: [String]
    public var changeReason: String

    public init(description: String, changeReason: String, status: RequirementStatus = .draft,
                preconditions: [String] = [], rules: [String] = [], acceptanceCriteria: [String] = [],
                validationRules: [String] = [], expectedBehavior: [String: KnowledgeValue] = [:],
                environmentScope: [EnvironmentID] = [], references: [String] = [],
                executableValidationRules: [RequirementValidationRule]? = nil) {
        self.description = description; self.changeReason = changeReason; self.status = status
        self.preconditions = preconditions; self.rules = rules; self.acceptanceCriteria = acceptanceCriteria
        self.validationRules = validationRules; self.expectedBehavior = expectedBehavior
        self.environmentScope = environmentScope; self.references = references
        self.executableValidationRules = executableValidationRules
    }
    public func validate() throws {
        try Self.checkText(description, maximum: 32_768); try Self.checkText(changeReason, maximum: 4_096)
        for list in [preconditions, rules, acceptanceCriteria, validationRules, references] {
            guard list.count <= 128 else { throw RequirementError.limitExceeded }
            for text in list { try Self.checkText(text, maximum: 8_192) }
        }
        guard environmentScope.count <= 128, Set(environmentScope).count == environmentScope.count else { throw RequirementError.invalidDocument }
        if let executableValidationRules {
            guard executableValidationRules.count <= 128,
                  Set(executableValidationRules.map(\.id)).count == executableValidationRules.count else { throw RequirementError.invalidDocument }
            for rule in executableValidationRules { try rule.validate() }
        }
        var nodes = 0; try KnowledgeValue.object(expectedBehavior).validate(nodes: &nodes)
    }
    static func checkText(_ text: String, maximum: Int, empty: Bool = false) throws {
        guard text.utf8.count <= maximum else { throw RequirementError.limitExceeded }
        guard empty || !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" && $0 != "\r" }) else {
            throw RequirementError.invalidDocument
        }
    }
}

public struct RequirementVersion: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let scope: ProjectScope
    public let id: RequirementID
    public let version: Int
    public let supersedes: Int?
    public let previousFingerprint: ActionFingerprint?
    public let createdAt: Date
    public let content: RequirementDraft
    public var fingerprint: ActionFingerprint { get throws { try ActionFingerprint.canonical(self) } }
    func validate() throws {
        guard schemaVersion == 1, (1...1_000_000).contains(version),
              supersedes == nil || (supersedes! > 0 && supersedes! < version),
              (supersedes == nil) == (previousFingerprint == nil),
              createdAt.timeIntervalSince1970.isFinite, createdAt.timeIntervalSince1970 >= 0 else { throw RequirementError.invalidDocument }
        try content.validate()
    }
}

/// A pending local review is bound to one store instance and expires after five minutes.
/// Runtime and mobile tools must not be given this native administrative publication boundary.
public struct RequirementProposal: Equatable, Sendable {
    public let token: UUID
    public let candidate: RequirementVersion
    public let expiresAt: Date
}

public enum RequirementSelection: Equatable, Sendable {
    case latestActive
    case latestPublished
    case historical(version: Int)
}
