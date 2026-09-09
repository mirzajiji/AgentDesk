import AgentDeskCore
import Foundation
import SQLite3

public typealias PersistedRunState = RunState

public struct StoredRun: Equatable, Sendable, Identifiable {
    public let id: RunID
    public let scope: ProjectScope
    public let createdAt: Date
    public let state: PersistedRunState
    public let sequence: Int64
}

public struct StoredRunEvent: Equatable, Sendable {
    public let runID: RunID
    public let scope: ProjectScope
    public let sequence: Int64
    public let state: PersistedRunState
    public let recordedAt: Date

    public init(runID: RunID, scope: ProjectScope, sequence: Int64, state: PersistedRunState, recordedAt: Date) {
        self.runID = runID; self.scope = scope; self.sequence = sequence; self.state = state; self.recordedAt = recordedAt
    }
}

/// Workspace-bound operational persistence. The caller must authorize project membership first.
/// No prompt, secret, provider output, or arbitrary SQL is accepted by this API.
public actor OperationalStore {
    public nonisolated let workspaceID: WorkspaceID
    private let database: SQLiteConnection

    public init(database location: URL, workspaceID: WorkspaceID) throws {
        let connection = try SQLiteConnection(database: location)
        try OperationalMigrations.apply(to: connection)
        database = connection
        self.workspaceID = workspaceID
    }

    public func createRun(in scope: ProjectScope, id: RunID = RunID(), at date: Date = Date()) throws -> StoredRun {
        try validate(scope)
        let timestamp = try Self.timestamp(date)
        return try database.transaction {
            try database.execute("INSERT INTO runs VALUES (?, ?, ?, ?, 'queued')",
                                 [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(id.rawValue), .real(timestamp)])
            try database.execute("INSERT INTO run_events VALUES (?, ?, ?, 1, 'queued', ?)",
                                 [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(id.rawValue), .real(timestamp)])
            return StoredRun(id: id, scope: scope, createdAt: date, state: .queued, sequence: 1)
        }
    }

    public func run(_ id: RunID, in scope: ProjectScope) throws -> StoredRun? {
        try validate(scope)
        return try loadRun(id, in: scope)
    }

    public func runs(in scope: ProjectScope, limit: Int = 100) throws -> [StoredRun] {
        try validate(scope)
        guard (1...1_000).contains(limit) else { throw OperationalStoreError.invalidInput }
        return try database.query(Self.runSelect + " WHERE r.workspace_id = ? AND r.project_id = ? ORDER BY r.created_at DESC, r.run_id LIMIT ?",
                                  [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .integer(Int64(limit))], map: Self.decodeRun)
    }

    /// Stores an authoritative lifecycle decision with optimistic sequence checking.
    /// Legal state transitions are enforced by the runtime lifecycle service, not inferred by storage.
    public func recordState(_ state: PersistedRunState, for id: RunID, in scope: ProjectScope,
                            expectedSequence: Int64, at date: Date = Date()) throws -> StoredRunEvent {
        try validate(scope)
        guard expectedSequence > 0, expectedSequence < Int64.max else { throw OperationalStoreError.invalidInput }
        let timestamp = try Self.timestamp(date)
        return try database.transaction {
            guard let existing = try loadRun(id, in: scope) else { throw OperationalStoreError.missingRun }
            guard existing.sequence == expectedSequence else { throw OperationalStoreError.staleSequence }
            guard timestamp >= existing.createdAt.timeIntervalSince1970 else { throw OperationalStoreError.invalidInput }
            let sequence = expectedSequence + 1
            let keys: [SQLValue] = [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(id.rawValue)]
            try database.execute("INSERT INTO run_events VALUES (?, ?, ?, ?, ?, ?)",
                                 keys + [.integer(sequence), .text(state.rawValue), .real(timestamp)])
            try database.execute("UPDATE runs SET state = ? WHERE workspace_id = ? AND project_id = ? AND run_id = ?",
                                 [.text(state.rawValue)] + keys)
            return StoredRunEvent(runID: id, scope: scope, sequence: sequence, state: state, recordedAt: date)
        }
    }

    public func events(for id: RunID, in scope: ProjectScope, after sequence: Int64 = 0,
                       limit: Int = 256) throws -> [StoredRunEvent] {
        try validate(scope)
        guard sequence >= 0, (1...1_000).contains(limit) else { throw OperationalStoreError.invalidInput }
        return try database.query("""
            SELECT sequence, state, recorded_at FROM run_events
            WHERE workspace_id = ? AND project_id = ? AND run_id = ? AND sequence > ?
            ORDER BY sequence LIMIT ?
            """, [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(id.rawValue),
                  .integer(sequence), .integer(Int64(limit))]) { statement in
            let sequence = sqlite3_column_int64(statement, 0)
            guard sequence > 0, let state = PersistedRunState(rawValue: try SQLiteConnection.text(statement, 1)) else {
                throw OperationalStoreError.invalidDatabase
            }
            let timestamp = sqlite3_column_double(statement, 2)
            guard timestamp.isFinite else { throw OperationalStoreError.invalidDatabase }
            return StoredRunEvent(runID: id, scope: scope, sequence: sequence, state: state,
                                  recordedAt: Date(timeIntervalSince1970: timestamp))
        }
    }

    private func validate(_ scope: ProjectScope) throws {
        try Task.checkCancellation()
        guard scope.workspaceID == workspaceID else { throw OperationalStoreError.scopeMismatch }
    }

    private func loadRun(_ id: RunID, in scope: ProjectScope) throws -> StoredRun? {
        let rows = try database.query(Self.runSelect + " WHERE r.workspace_id = ? AND r.project_id = ? AND r.run_id = ?",
                                      [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(id.rawValue)], map: Self.decodeRun)
        guard rows.count <= 1 else { throw OperationalStoreError.invalidDatabase }
        return rows.first
    }

    private static let runSelect = """
        SELECT r.workspace_id, r.project_id, r.run_id, r.created_at, r.state,
        (SELECT MAX(e.sequence) FROM run_events e
          WHERE e.workspace_id = r.workspace_id AND e.project_id = r.project_id AND e.run_id = r.run_id)
        FROM runs r
        """

    private static func decodeRun(_ statement: OpaquePointer) throws -> StoredRun {
        guard let workspace = WorkspaceID(rawValue: try SQLiteConnection.text(statement, 0)),
              let project = ProjectID(rawValue: try SQLiteConnection.text(statement, 1)),
              let id = RunID(rawValue: try SQLiteConnection.text(statement, 2)),
              let state = PersistedRunState(rawValue: try SQLiteConnection.text(statement, 4)),
              sqlite3_column_type(statement, 5) == SQLITE_INTEGER else { throw OperationalStoreError.invalidDatabase }
        let timestamp = sqlite3_column_double(statement, 3), sequence = sqlite3_column_int64(statement, 5)
        guard timestamp.isFinite, sequence > 0 else { throw OperationalStoreError.invalidDatabase }
        return StoredRun(id: id, scope: ProjectScope(workspaceID: workspace, projectID: project),
                         createdAt: Date(timeIntervalSince1970: timestamp), state: state, sequence: sequence)
    }

    private static func timestamp(_ date: Date) throws -> Double {
        let value = date.timeIntervalSince1970
        guard value.isFinite, value >= 0 else { throw OperationalStoreError.invalidInput }
        return value
    }
}
