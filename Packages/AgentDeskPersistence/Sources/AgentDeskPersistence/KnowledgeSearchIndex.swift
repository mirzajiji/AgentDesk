import AgentDeskCore
import AgentDeskSecurity
import Foundation
import SQLite3

public enum KnowledgeIndexError: Error, Equatable, Sendable { case notBuilt, staleGeneration, invalidInput, limitExceeded }
public struct KnowledgeSearchHit: Equatable, Sendable {
    public let sourceID: String
    public let path: KnowledgePath
    public let kind: KnowledgeRecordKind
    public let revision: Int
    public let fingerprint: ActionFingerprint
    public let title: String
    public let bodyJSON: String
}
public struct KnowledgeSearchCursor: Equatable, Sendable {
    let scope: ProjectScope
    let environment: EnvironmentID
    let generation: Int
    let query: ActionFingerprint
    let path: KnowledgePath
    let sourceID: String
}
public struct KnowledgeSearchPage: Sendable {
    public let scope: ProjectScope
    public let environment: EnvironmentID
    public let generation: Int
    public let hits: [KnowledgeSearchHit]
    public let hasMore: Bool
    public let nextCursor: KnowledgeSearchCursor?
}

/// Non-authoritative, redacted FTS cache for one exact project/environment. No raw SQL is exposed.
public actor KnowledgeSearchIndex {
    public nonisolated let scope: ProjectScope
    public nonisolated let environment: EnvironmentID
    private let database: SQLiteConnection
    public init(database location: URL, scope: ProjectScope, environment: EnvironmentID) throws {
        let connection = try SQLiteConnection(database: location)
        try OperationalMigrations.apply(to: connection)
        database = connection; self.scope = scope; self.environment = environment
    }
    /// Collect current authoritative records. A failed collection/redaction leaves the previous index intact.
    public func rebuild(memory: ProjectMemoryStore, requirements: ProjectRequirementStore,
                        redactor: ContentRedactor, expectedGeneration: Int? = nil) async throws -> Int {
        guard memory.scope == scope, requirements.scope == scope else { throw OperationalStoreError.scopeMismatch }
        var documents: [KnowledgeIndexDocument] = [], memoryCursor: MemoryID?, requirementCursor: RequirementID?
        while true {
            try Task.checkCancellation()
            let page = try await memory.list(in: scope, environment: environment, after: memoryCursor, limit: 100)
            documents += try page.map { try KnowledgeIndexDocument(memory: $0) }
            guard documents.count <= 1_000 else { throw KnowledgeIndexError.limitExceeded }
            guard page.count == 100 else { break }; memoryCursor = page.last?.id
        }
        while true {
            try Task.checkCancellation()
            let page = try await requirements.list(in: scope, after: requirementCursor, limit: 100)
            for head in page {
                if let active = try await requirements.resolve(head.id, in: scope, environment: environment) {
                    documents.append(try KnowledgeIndexDocument(requirement: active))
                }
            }
            guard documents.count <= 1_000 else { throw KnowledgeIndexError.limitExceeded }
            guard page.count == 100 else { break }; requirementCursor = page.last?.id
        }
        return try rebuild(documents, redactor: redactor, expectedGeneration: expectedGeneration)
    }
    public func rebuild(_ documents: [KnowledgeIndexDocument], redactor: ContentRedactor,
                        expectedGeneration: Int? = nil) throws -> Int {
        try Task.checkCancellation()
        guard redactor.context.scope == scope, redactor.context.environmentID == environment,
              documents.allSatisfy({ $0.scope == scope && ($0.environments.isEmpty || $0.environments.contains(environment)) }) else {
            throw OperationalStoreError.scopeMismatch
        }
        guard documents.count <= 1_000, Set(documents.map(\.sourceID)).count == documents.count else { throw KnowledgeIndexError.limitExceeded }
        var bytes = 0
        let sanitized = try documents.map { document -> (KnowledgeIndexDocument, String, String) in
            let title = try redactor.redactText(document.title, in: redactor.context).text
            let body = try redactor.redactJSON(document.bodyJSON, in: redactor.context).text
            guard try redactor.redactText(document.path.rawValue, in: redactor.context).text == document.path.rawValue,
                  title.utf8.count <= 65_536, body.utf8.count <= 262_144 else { throw KnowledgeIndexError.invalidInput }
            bytes += title.utf8.count + body.utf8.count
            guard bytes <= 16_777_216 else { throw KnowledgeIndexError.limitExceeded }
            return (document, title, body)
        }
        return try database.transaction {
            let prior = try generation()
            if let expectedGeneration, prior != expectedGeneration { throw KnowledgeIndexError.staleGeneration }
            guard prior < Int.max else { throw KnowledgeIndexError.limitExceeded }
            try database.execute("DELETE FROM knowledge_fts WHERE workspace_id=? AND project_id=? AND environment_id=?", identity)
            for (document, title, body) in sanitized {
                try database.execute("INSERT INTO knowledge_fts VALUES (?,?,?,?,?,?,?,?,?,?)", identity + [
                    .text(document.sourceID), .text(document.path.rawValue), .text(document.kind.rawValue),
                    .integer(Int64(document.revision)), .text(document.fingerprint.rawValue), .text(title), .document(body)])
            }
            let next = prior + 1
            try database.execute("INSERT INTO knowledge_generations VALUES (?,?,?,?) ON CONFLICT(workspace_id,project_id,environment_id) DO UPDATE SET generation=excluded.generation",
                                 identity + [.integer(Int64(next))])
            return next
        }
    }
    public func search(_ text: String, in requested: ProjectScope, environment requestedEnvironment: EnvironmentID,
                       kinds: Set<KnowledgeRecordKind> = [.requirement, .confirmed],
                       paths: KnowledgePathFilter = try! KnowledgePathFilter(), after: KnowledgeSearchCursor? = nil, limit: Int = 50) throws -> KnowledgeSearchPage {
        guard requested == scope, requestedEnvironment == environment else { throw OperationalStoreError.scopeMismatch }
        guard text.utf8.count <= 1_024, !text.utf8.contains(0), (1...100).contains(limit) else { throw KnowledgeIndexError.invalidInput }
        let terms = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard terms.count <= 16, terms.allSatisfy({ $0.utf8.count <= 128 }) else { throw KnowledgeIndexError.invalidInput }
        let query = try ActionFingerprint.canonical(QueryBinding(text: text, kinds: kinds.map(\.rawValue).sorted(), include: paths.include, exclude: paths.exclude))
        if let after {
            guard after.scope == scope, after.environment == environment, after.query == query else { throw KnowledgeIndexError.invalidInput }
        }
        var predicates = ["workspace_id=?", "project_id=?", "environment_id=?"]
        var values = identity
        if !terms.isEmpty {
            predicates.append("knowledge_fts MATCH ?")
            values.append(.text(terms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")))
        }
        let sortedKinds = kinds.map(\.rawValue).sorted()
        predicates.append(sortedKinds.isEmpty ? "0" : "kind IN (" + Array(repeating: "?", count: sortedKinds.count).joined(separator: ",") + ")")
        values += sortedKinds.map(SQLValue.text)
        predicates.append(Self.pathClause(paths.include, values: &values))
        if !paths.exclude.isEmpty { predicates.append("NOT (" + Self.pathClause(paths.exclude, values: &values) + ")") }
        if let after {
            predicates.append("(path>? OR (path=? AND source_id>?))")
            values += [.text(after.path.rawValue), .text(after.path.rawValue), .text(after.sourceID)]
        }
        return try database.transaction {
            let generation = try generation()
            guard generation > 0 else { throw KnowledgeIndexError.notBuilt }
            if let after, after.generation != generation { throw KnowledgeIndexError.staleGeneration }
            let rows = try database.query("SELECT source_id,path,kind,revision,fingerprint,title,body FROM knowledge_fts WHERE " + predicates.joined(separator: " AND ") + " ORDER BY path,source_id LIMIT ?",
                                          values + [.integer(Int64(limit + 1))], map: Self.decode)
            let hits = Array(rows.prefix(limit)), hasMore = rows.count > limit
            let cursor = hasMore ? hits.last.map { KnowledgeSearchCursor(scope: scope, environment: environment,
                generation: generation, query: query, path: $0.path, sourceID: $0.sourceID) } : nil
            return KnowledgeSearchPage(scope: scope, environment: environment, generation: generation,
                                       hits: hits, hasMore: hasMore, nextCursor: cursor)
        }
    }
    private struct QueryBinding: Encodable {
        let text: String
        let kinds: [String]
        let include: [String]
        let exclude: [String]
    }
    private var identity: [SQLValue] { [.text(scope.workspaceID.rawValue), .text(scope.projectID.rawValue), .text(environment.rawValue)] }
    private func generation() throws -> Int {
        try database.query("SELECT generation FROM knowledge_generations WHERE workspace_id=? AND project_id=? AND environment_id=?", identity,
                           map: { Int(sqlite3_column_int64($0, 0)) }).first ?? 0
    }
    private static func pathClause(_ patterns: [String], values: inout [SQLValue]) -> String {
        let clauses = patterns.map { pattern -> String in
            if pattern == "**" { return "1" }
            if pattern.hasSuffix("/**") {
                let prefix = String(pattern.dropLast(3))
                values += [.text(prefix), .text(prefix + "/*")]
                return "(path=? OR path GLOB ?)"
            }
            values.append(.text(pattern)); return "path=?"
        }
        return "(" + (clauses.isEmpty ? "0" : clauses.joined(separator: " OR ")) + ")"
    }
    private static func decode(_ row: OpaquePointer) throws -> KnowledgeSearchHit {
        let sourceID = try SQLiteConnection.text(row, 0)
        guard let path = try KnowledgePath(rawValue: SQLiteConnection.text(row, 1)),
              let kind = try KnowledgeRecordKind(rawValue: SQLiteConnection.text(row, 2)),
              let fingerprint = try ActionFingerprint(rawValue: SQLiteConnection.text(row, 4)) else { throw OperationalStoreError.invalidDatabase }
        let revision = Int(sqlite3_column_int64(row, 3))
        guard (1...1_000_000).contains(revision),
              (kind == .requirement && sourceID.hasPrefix("requirement/") && RequirementID(rawValue: String(sourceID.dropFirst(12))) != nil) ||
              (kind != .requirement && sourceID.hasPrefix("memory/") && MemoryID(rawValue: String(sourceID.dropFirst(7))) != nil) else {
            throw OperationalStoreError.invalidDatabase
        }
        return KnowledgeSearchHit(sourceID: sourceID, path: path, kind: kind, revision: revision, fingerprint: fingerprint,
                                  title: try SQLiteConnection.text(row, 5), bodyJSON: try SQLiteConnection.text(row, 6, maximumBytes: 262_144))
    }
}
