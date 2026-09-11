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
        try database.query("SELECT record_json FROM mutation_attempts WHERE workspace_id=? AND project_id=? AND environment_id=? AND action_id=?",
            context + [.text(actionID.uuidString)]) { row in
                let text = try SQLiteConnection.text(row, 0)
                let value = try JSONDecoder().decode(MutationAttemptRecord.self, from: Data(text.utf8))
                guard value.action.id == actionID, value.action.scope == scope,
                      value.action.environmentID == environmentID,
                      [.externalMutation, .destructiveAction].contains(value.action.operation),
                      value.startedAt.timeIntervalSince1970.isFinite,
                      value.updatedAt.timeIntervalSince1970.isFinite, value.updatedAt >= value.startedAt else {
                    throw OperationalStoreError.invalidDatabase
                }
                return value
            }.first
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
