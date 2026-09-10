import Foundation

/// Explicit retrieval preferences, never an access grant. Nil on an agent means no knowledge retrieval.
public struct AgentKnowledgeSelection: Codable, Equatable, Sendable {
    public let paths: KnowledgePathFilter
    public let query: String
    public let kinds: [KnowledgeRecordKind]
    public let maximumRecords: Int
    public let maximumBytes: Int
    public let relationships: [TraceabilitySubject]

    public init(paths: KnowledgePathFilter, query: String = "",
                kinds: [KnowledgeRecordKind] = [.requirement, .confirmed],
                maximumRecords: Int = 12, maximumBytes: Int = 24_576,
                relationships: [TraceabilitySubject] = []) throws {
        self.paths = paths; self.query = query; self.kinds = kinds
        self.maximumRecords = maximumRecords; self.maximumBytes = maximumBytes
        self.relationships = relationships
        try validate()
    }
    public func validate() throws {
        let terms = query.split(whereSeparator: \.isWhitespace)
        guard query.utf8.count <= 1_024, !query.utf8.contains(0), terms.count <= 16,
              terms.allSatisfy({ $0.utf8.count <= 128 }),
              !kinds.isEmpty, kinds.count <= 4, Set(kinds).count == kinds.count,
              (1...32).contains(maximumRecords), (1_024...32_768).contains(maximumBytes),
              relationships.count <= 16, Set(relationships).count == relationships.count else {
            throw AgentConfigurationError.invalidConfiguration
        }
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case paths, query, kinds, maximumRecords, maximumBytes, relationships
    }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownConfigurationKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(paths: values.decode(KnowledgePathFilter.self, forKey: .paths),
            query: values.decode(String.self, forKey: .query),
            kinds: values.decode([KnowledgeRecordKind].self, forKey: .kinds),
            maximumRecords: values.decode(Int.self, forKey: .maximumRecords),
            maximumBytes: values.decode(Int.self, forKey: .maximumBytes),
            relationships: values.decode([TraceabilitySubject].self, forKey: .relationships))
    }
}
