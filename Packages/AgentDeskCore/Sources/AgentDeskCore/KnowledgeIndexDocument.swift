import Foundation

public struct KnowledgePath: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String
    public init?(rawValue: String) {
        let parts = rawValue.split(separator: "/", omittingEmptySubsequences: false)
        guard rawValue.utf8.count <= 1_024, (1...16).contains(parts.count), parts.allSatisfy({ part in
            !part.isEmpty && part != "." && part != ".." && part.utf8.count <= 96 &&
            part.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 || $0 == 46 }
        }) else { return nil }
        self.rawValue = rawValue
    }
    public init(from decoder: any Decoder) throws {
        guard let value = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) else { throw RequirementError.invalidDocument }
        self = value
    }
    public func encode(to encoder: any Encoder) throws { var value = encoder.singleValueContainer(); try value.encode(rawValue) }
}

public struct KnowledgePathFilter: Codable, Equatable, Sendable {
    public let include: [String]
    public let exclude: [String]
    public init(include: [String] = ["**"], exclude: [String] = []) throws {
        guard include.count <= 32, exclude.count <= 32 else { throw RequirementError.limitExceeded }
        for pattern in include + exclude {
            guard pattern == "**" || KnowledgePath(rawValue: pattern.hasSuffix("/**") ? String(pattern.dropLast(3)) : pattern) != nil else {
                throw RequirementError.invalidDocument
            }
        }
        self.include = include; self.exclude = exclude
    }
    private enum CodingKeys: String, CodingKey { case include, exclude }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownConfigurationKeys(decoder, allowed: ["include", "exclude"])
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(include: values.decode([String].self, forKey: .include),
                      exclude: values.decode([String].self, forKey: .exclude))
    }
    public func permits(_ path: KnowledgePath) -> Bool {
        func matches(_ pattern: String) -> Bool {
            if pattern == "**" { return true }
            if pattern.hasSuffix("/**") {
                let prefix = String(pattern.dropLast(3))
                return path.rawValue == prefix || path.rawValue.hasPrefix(prefix + "/")
            }
            return path.rawValue == pattern
        }
        return include.contains(where: matches) && !exclude.contains(where: matches)
    }
}

public enum KnowledgeRecordKind: String, Codable, CaseIterable, Sendable { case requirement, confirmed, note, inbox }

/// Rebuildable source snapshot. Search consumers must revalidate against authoritative stores before dispatch.
public struct KnowledgeIndexDocument: Sendable {
    public let scope: ProjectScope
    public let sourceID: String
    public let path: KnowledgePath
    public let kind: KnowledgeRecordKind
    public let revision: Int
    public let fingerprint: ActionFingerprint
    public let environments: [EnvironmentID]
    public let title: String
    public let bodyJSON: String
    public init(memory: MemoryRecord) throws {
        try memory.validate()
        guard memory.content.disposition == .active else { throw RequirementError.invalidDocument }
        scope = memory.scope; sourceID = "memory/\(memory.id)"; revision = memory.revision
        fingerprint = try memory.fingerprint; environments = memory.content.environmentScope
        kind = switch memory.content.kind { case .confirmed: .confirmed; case .note: .note; case .inbox: .inbox }
        let prefix: String = switch memory.content.topic {
        case .architecture: "architecture"
        case .apiBehavior: "api"
        case .qaDecision, .testExpectation, .discoveredBehavior: "qa"
        case .businessRule, .stateTransition, .environmentRule: "behavior"
        case .projectDescription: "overview"
        case .terminology: "terminology"
        case .documentation: "docs"
        case .unclassified: memory.content.kind.rawValue
        }
        path = memory.content.knowledgePath ?? KnowledgePath(rawValue: "\(prefix)/\(memory.id)")!
        title = memory.content.title; bodyJSON = try Self.json(memory)
    }
    public init(requirement: RequirementVersion) throws {
        try requirement.validate()
        guard requirement.content.status == .active else { throw RequirementError.invalidDocument }
        scope = requirement.scope; sourceID = "requirement/\(requirement.id)"; revision = requirement.version
        fingerprint = try requirement.fingerprint; environments = requirement.content.environmentScope
        path = KnowledgePath(rawValue: "requirements/\(requirement.id)")!; kind = .requirement
        title = requirement.id.rawValue; bodyJSON = try Self.json(requirement)
    }
    private static func json<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= 262_144 else { throw RequirementError.limitExceeded }
        return String(decoding: data, as: UTF8.self)
    }
}
