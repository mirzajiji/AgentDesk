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
    public enum Kind: String, Codable, Sendable { case runState, progress }
    public let runID: RunID
    public let scope: ProjectScope
    public let sequence: Int64
    public let state: PersistedRunState
    public let recordedAt: Date
    public let kind: Kind
    public let progress: RunWorkPlan?

    public init(runID: RunID, scope: ProjectScope, sequence: Int64, state: PersistedRunState, recordedAt: Date,
                kind: Kind = .runState, progress: RunWorkPlan? = nil) {
        self.runID = runID; self.scope = scope; self.sequence = sequence; self.state = state; self.recordedAt = recordedAt
        self.kind = kind; self.progress = progress
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

    public func createRun(in scope: ProjectScope, id: RunID = RunID(), at inputDate: Date = Date()) throws -> StoredRun {
        try validate(scope)
        let timestamp = try Self.timestamp(inputDate)
        let date = Date(timeIntervalSince1970: timestamp)
        return try database.transaction {
            try database.execute("INSERT INTO runs VALUES (?, ?, ?, ?, 'queued')",
                                 [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(id.rawValue), .real(timestamp)])
            try database.execute("INSERT INTO run_events (workspace_id, project_id, run_id, sequence, state, recorded_at) VALUES (?, ?, ?, 1, 'queued', ?)",
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

    /// Stable keyset pagination for the local project owner recovering interrupted runs.
    public func unfinishedRuns(in scope: ProjectScope, afterRunID: RunID? = nil, limit: Int = 256) throws -> [StoredRun] {
        try validate(scope)
        guard (1...256).contains(limit) else { throw OperationalStoreError.invalidInput }
        return try database.query(Self.runSelect + " WHERE r.workspace_id=? AND r.project_id=? AND r.run_id>? AND r.state NOT IN ('completed','failed','cancelled') ORDER BY r.run_id LIMIT ?",
            [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(afterRunID?.rawValue ?? ""), .integer(Int64(limit))], map: Self.decodeRun)
    }

    public func evidenceBinding(for id: RunID, in scope: ProjectScope) throws -> EvidenceRunBinding? {
        try validate(scope)
        return try database.query("SELECT environment_id,binding_json FROM evidence_runs WHERE workspace_id=? AND project_id=? AND run_id=?",
            [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(id.rawValue)]) { statement in
            do {
                let binding = try JSONDecoder().decode(EvidenceRunBinding.self,
                    from: Data(SQLiteConnection.text(statement, 1, maximumBytes: 131_072).utf8))
                try binding.validate()
                guard binding.context.scope == scope, binding.context.runID == id,
                      binding.context.environmentID.rawValue == (try SQLiteConnection.text(statement, 0)) else {
                    throw OperationalStoreError.invalidDatabase
                }
                return binding
            } catch { throw OperationalStoreError.invalidDatabase }
        }.first
    }

    /// Stores an authoritative lifecycle decision with optimistic sequence checking.
    /// Legal state transitions are enforced by the runtime lifecycle service, not inferred by storage.
    public func recordState(_ state: PersistedRunState, for id: RunID, in scope: ProjectScope,
                            expectedSequence: Int64, at inputDate: Date = Date()) throws -> StoredRunEvent {
        try validate(scope)
        guard expectedSequence > 0, expectedSequence < Int64.max else { throw OperationalStoreError.invalidInput }
        let timestamp = try Self.timestamp(inputDate)
        let date = Date(timeIntervalSince1970: timestamp)
        return try database.transaction {
            guard let existing = try loadRun(id, in: scope) else { throw OperationalStoreError.missingRun }
            guard existing.sequence == expectedSequence else { throw OperationalStoreError.staleSequence }
            try validateEventDate(timestamp, run: existing)
            let sequence = expectedSequence + 1
            let keys: [SQLValue] = [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(id.rawValue)]
            let progress = state.isTerminal ? try loadProgress(id, in: scope)?.ending(with: state, at: date) : nil
            if let progress {
                let json = try Self.encodeProgress(progress)
                try database.execute("UPDATE run_progress SET plan_json = ? WHERE workspace_id = ? AND project_id = ? AND run_id = ?",
                                     [.json(json)] + keys)
            }
            try insertEvent(id, scope: scope, sequence: sequence, state: state, date: date, kind: .runState, progress: progress)
            try database.execute("UPDATE runs SET state = ? WHERE workspace_id = ? AND project_id = ? AND run_id = ?",
                                 [.text(state.rawValue)] + keys)
            return StoredRunEvent(runID: id, scope: scope, sequence: sequence, state: state, recordedAt: date, progress: progress)
        }
    }

    public func events(for id: RunID, in scope: ProjectScope, after sequence: Int64 = 0,
                       limit: Int = 256) throws -> [StoredRunEvent] {
        try validate(scope)
        guard sequence >= 0, (1...1_000).contains(limit) else { throw OperationalStoreError.invalidInput }
        return try database.query("""
            SELECT sequence, state, recorded_at, event_kind, progress_json FROM run_events
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
            guard let kind = StoredRunEvent.Kind(rawValue: try SQLiteConnection.text(statement, 3)) else {
                throw OperationalStoreError.invalidDatabase
            }
            let progress = sqlite3_column_type(statement, 4) == SQLITE_NULL ? nil : try Self.decodeProgress(SQLiteConnection.text(statement, 4, maximumBytes: 131_072), id: id, scope: scope)
            guard kind != .progress || progress != nil else { throw OperationalStoreError.invalidDatabase }
            return StoredRunEvent(runID: id, scope: scope, sequence: sequence, state: state,
                                  recordedAt: Date(timeIntervalSince1970: timestamp), kind: kind, progress: progress)
        }
    }

    public func progressPlan(for id: RunID, in scope: ProjectScope) throws -> RunWorkPlan? {
        try validate(scope)
        return try loadProgress(id, in: scope)
    }

    public func configureProgress(_ plan: RunWorkPlan, in scope: ProjectScope, expectedSequence: Int64,
                                  at inputDate: Date = Date()) throws -> StoredRunEvent {
        try validate(scope)
        let date = Date(timeIntervalSince1970: try Self.timestamp(inputDate))
        guard plan.scope == scope else { throw OperationalStoreError.scopeMismatch }
        try plan.validate()
        guard plan.items.allSatisfy({ $0.state == .pending }) else { throw OperationalStoreError.invalidInput }
        return try database.transaction {
            let run = try checkedRun(plan.runID, scope: scope, expectedSequence: expectedSequence, date: date)
            guard run.state == .queued else { throw WorkPlanError.invalidTransition }
            try database.execute("INSERT INTO run_progress VALUES (?, ?, ?, ?)",
                [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(plan.runID.rawValue), .json(Self.encodeProgress(plan))])
            try insertEvent(plan.runID, scope: scope, sequence: expectedSequence + 1, state: run.state, date: date, kind: .progress, progress: plan)
            return StoredRunEvent(runID: plan.runID, scope: scope, sequence: expectedSequence + 1, state: run.state,
                                  recordedAt: date, kind: .progress, progress: plan)
        }
    }

    public func changeProgress(_ change: WorkPlanChange, for id: RunID, in scope: ProjectScope, expectedSequence: Int64,
                               at inputDate: Date = Date()) throws -> StoredRunEvent {
        try validate(scope)
        let date = Date(timeIntervalSince1970: try Self.timestamp(inputDate))
        return try database.transaction {
            let run = try checkedRun(id, scope: scope, expectedSequence: expectedSequence, date: date)
            guard run.state == .running else { throw WorkPlanError.invalidTransition }
            guard let existing = try loadProgress(id, in: scope) else { throw WorkPlanError.invalidPlan }
            let updated = try existing.applying(change, at: date)
            try database.execute("UPDATE run_progress SET plan_json = ? WHERE workspace_id = ? AND project_id = ? AND run_id = ?",
                [.json(Self.encodeProgress(updated)), .text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(id.rawValue)])
            try insertEvent(id, scope: scope, sequence: expectedSequence + 1, state: run.state, date: date, kind: .progress, progress: updated)
            return StoredRunEvent(runID: id, scope: scope, sequence: expectedSequence + 1, state: run.state,
                                  recordedAt: date, kind: .progress, progress: updated)
        }
    }

    private func checkedRun(_ id: RunID, scope: ProjectScope, expectedSequence: Int64, date: Date) throws -> StoredRun {
        guard expectedSequence > 0, expectedSequence < Int64.max else { throw OperationalStoreError.invalidInput }
        guard let run = try loadRun(id, in: scope) else { throw OperationalStoreError.missingRun }
        guard run.sequence == expectedSequence else { throw OperationalStoreError.staleSequence }
        try validateEventDate(Self.timestamp(date), run: run)
        return run
    }

    private func validateEventDate(_ timestamp: Double, run: StoredRun) throws {
        let dates = try database.query("SELECT recorded_at FROM run_events WHERE workspace_id = ? AND project_id = ? AND run_id = ? AND sequence = ?",
            [.text(workspaceID.rawValue), .text(run.scope.projectID.rawValue), .text(run.id.rawValue), .integer(run.sequence)]) { sqlite3_column_double($0, 0) }
        guard let previous = dates.first, previous.isFinite else { throw OperationalStoreError.invalidDatabase }
        guard timestamp >= previous, timestamp >= run.createdAt.timeIntervalSince1970 else { throw OperationalStoreError.invalidInput }
    }

    private func insertEvent(_ id: RunID, scope: ProjectScope, sequence: Int64, state: RunState, date: Date,
                             kind: StoredRunEvent.Kind, progress: RunWorkPlan?) throws {
        let keys: [SQLValue] = [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(id.rawValue),
                              .integer(sequence), .text(state.rawValue), .real(date.timeIntervalSince1970), .text(kind.rawValue)]
        if let progress {
            try database.execute("INSERT INTO run_events VALUES (?, ?, ?, ?, ?, ?, ?, ?)", keys + [.json(Self.encodeProgress(progress))])
        } else {
            try database.execute("INSERT INTO run_events VALUES (?, ?, ?, ?, ?, ?, ?, NULL)", keys)
        }
    }

    private func loadProgress(_ id: RunID, in scope: ProjectScope) throws -> RunWorkPlan? {
        try database.query("SELECT plan_json FROM run_progress WHERE workspace_id = ? AND project_id = ? AND run_id = ?",
            [.text(workspaceID.rawValue), .text(scope.projectID.rawValue), .text(id.rawValue)]) {
                try Self.decodeProgress(SQLiteConnection.text($0, 0, maximumBytes: 131_072), id: id, scope: scope)
            }.first
    }

    private static func encodeProgress(_ progress: RunWorkPlan) throws -> String {
        try progress.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(progress)
        guard bytes.count <= 131_072, let value = String(data: bytes, encoding: .utf8) else { throw WorkPlanError.limitExceeded }
        return value
    }

    private static func decodeProgress(_ value: String, id: RunID, scope: ProjectScope) throws -> RunWorkPlan {
        do {
            let plan = try JSONDecoder().decode(RunWorkPlan.self, from: Data(value.utf8))
            guard plan.scope == scope, plan.runID == id else { throw OperationalStoreError.scopeMismatch }
            try plan.validate()
            return plan
        } catch { throw OperationalStoreError.invalidDatabase }
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
