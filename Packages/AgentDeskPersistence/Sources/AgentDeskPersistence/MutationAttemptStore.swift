import AgentDeskCore
import Foundation

/// An unfinished attempt is uncertain after restart, never proof that no write happened.
public enum MutationAttemptOutcome: String, Codable, Sendable {
    case unresolved, acknowledged, rejected, notDispatched
}
public struct MutationAttemptRecord: Codable, Equatable, Sendable {
    public let action: PolicyAction
    public let approvalID: UUID
    public let startedAt: Date
    public let updatedAt: Date
    public let outcome: MutationAttemptOutcome
}

public struct MutationAttemptPage: Sendable {
    public let records: [MutationAttemptRecord]
    public let nextActionID: UUID?
}

/// Operational evidence only. The caller must consume an exact approval before beginning.
/// No remote response text or credentials are accepted by this ledger.
public actor MutationAttemptStore {
    public nonisolated let scope: ProjectScope
    public nonisolated let environmentID: EnvironmentID
    private let database: SQLiteConnection
    private var context: [SQLValue] { [.text(scope.workspaceID.rawValue), .text(scope.projectID.rawValue), .text(environmentID.rawValue)] }
    public init(database location: URL, scope: ProjectScope, environmentID: EnvironmentID) throws {
        database = try SQLiteConnection(database: location)
        try OperationalMigrations.apply(to: database)
        self.scope = scope; self.environmentID = environmentID
    }
    public func record(_ actionID: UUID) throws -> MutationAttemptRecord? {
        try database.query("SELECT action_id,record_json FROM mutation_attempts WHERE workspace_id=? AND project_id=? AND environment_id=? AND action_id=?",
            context + [.text(actionID.uuidString)], map: decode).first
    }
    /// Stable key pagination, not chronological ordering. Refresh to include newly inserted keys
    /// before the cursor; outcome changes do not shift existing records between pages.
    public func page(after actionID: UUID? = nil, limit: Int = 50) throws -> MutationAttemptPage {
        guard (1...100).contains(limit) else { throw AuthorizationError.invalidInput }
        var sql = "SELECT action_id,record_json FROM mutation_attempts WHERE workspace_id=? AND project_id=? AND environment_id=?"
        var values = context
        if let actionID { sql += " AND action_id>?"; values.append(.text(actionID.uuidString)) }
        sql += " ORDER BY action_id LIMIT ?"
        values.append(.integer(Int64(limit + 1)))
        let found = try database.query(sql, values, map: decode)
        let records = Array(found.prefix(limit))
        return MutationAttemptPage(records: records, nextActionID: found.count > limit ? records.last?.action.id : nil)
    }
    private func decode(_ row: OpaquePointer) throws -> MutationAttemptRecord {
        guard let actionID = UUID(uuidString: try SQLiteConnection.text(row, 0)) else { throw OperationalStoreError.invalidDatabase }
        let text = try SQLiteConnection.text(row, 1)
        let value = try JSONDecoder().decode(MutationAttemptRecord.self, from: Data(text.utf8))
        guard value.action.id == actionID, value.action.scope == scope,
              value.action.environmentID == environmentID,
              [.externalMutation, .destructiveAction].contains(value.action.operation),
              value.startedAt.timeIntervalSince1970.isFinite,
              value.updatedAt.timeIntervalSince1970.isFinite, value.updatedAt >= value.startedAt else {
            throw OperationalStoreError.invalidDatabase
        }
        return value
    }
    public func begin(_ action: PolicyAction, approvalID: UUID, at now: Date) throws -> MutationAttemptRecord {
        guard action.scope == scope, action.environmentID == environmentID else { throw AuthorizationError.scopeMismatch }
        guard [.externalMutation, .destructiveAction].contains(action.operation), now.timeIntervalSince1970.isFinite else {
            throw AuthorizationError.invalidInput
        }
        return try database.transaction {
            guard try record(action.id) == nil else { throw AuthorizationError.alreadyUsed }
            let value = MutationAttemptRecord(action: action, approvalID: approvalID, startedAt: now, updatedAt: now, outcome: .unresolved)
            let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            try database.execute("INSERT INTO mutation_attempts VALUES (?,?,?,?,?)", context + [.text(action.id.uuidString), .json(text)])
            return value
        }
    }
    public func finish(_ action: PolicyAction, approvalID: UUID, outcome: MutationAttemptOutcome, at now: Date) throws -> MutationAttemptRecord {
        guard action.scope == scope, action.environmentID == environmentID else { throw AuthorizationError.scopeMismatch }
        guard outcome != .unresolved, now.timeIntervalSince1970.isFinite else { throw AuthorizationError.invalidInput }
        return try database.transaction {
            guard let previous = try record(action.id), previous.action == action, previous.approvalID == approvalID else {
                throw AuthorizationError.invalidApproval
            }
            guard previous.outcome == .unresolved else { throw AuthorizationError.alreadyUsed }
            guard now >= previous.updatedAt else { throw AuthorizationError.clockRegression }
            let value = MutationAttemptRecord(action: action, approvalID: approvalID, startedAt: previous.startedAt, updatedAt: now, outcome: outcome)
            let text = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
            try database.execute("UPDATE mutation_attempts SET record_json=? WHERE workspace_id=? AND project_id=? AND environment_id=? AND action_id=?",
                [.json(text)] + context + [.text(action.id.uuidString)])
            return value
        }
    }
}
