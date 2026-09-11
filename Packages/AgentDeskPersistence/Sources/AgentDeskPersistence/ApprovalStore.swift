import AgentDeskCore
import Foundation
import SQLite3

/// Exact project/environment ledger. The runtime gate authenticates and rechecks policy;
/// this lower-level store supplies durable, atomic approval transitions and replay protection.
public actor ApprovalStore {
    public nonisolated let scope: ProjectScope
    public nonisolated let environmentID: EnvironmentID
    private nonisolated let location: URL
    private let database: SQLiteConnection
    private var context: [SQLValue] { [.text(scope.workspaceID.rawValue), .text(scope.projectID.rawValue), .text(environmentID.rawValue)] }

    public init(database location: URL, scope: ProjectScope, environmentID: EnvironmentID) throws {
        let database = try SQLiteConnection(database: location); try OperationalMigrations.apply(to: database)
        self.location = location
        self.database = database; self.scope = scope; self.environmentID = environmentID
    }
    public nonisolated func mutationAttempts() throws -> MutationAttemptStore {
        try MutationAttemptStore(database: location, scope: scope, environmentID: environmentID)
    }
    public func approval(_ id: UUID) throws -> ApprovalRecord? { try load(id) }
    public func approvals(limit: Int = 100) throws -> [ApprovalRecord] {
        guard (1...1_000).contains(limit) else { throw AuthorizationError.invalidInput }
        return try database.query(Self.select + " WHERE workspace_id=? AND project_id=? AND environment_id=? ORDER BY created_at DESC, approval_id LIMIT ?",
                                  context + [.integer(Int64(limit))], map: decode)
    }
    public func prepare(_ action: PolicyAction, requesterID: UUID, policy: ActionFingerprint, id: UUID = UUID(),
                        at now: Date, expiresAt: Date) throws -> ApprovalRecord {
        try validate(action)
        return try database.transaction {
            if let prior = try byAction(action.id) {
                guard prior.action == action, prior.requesterID == requesterID else { throw AuthorizationError.invalidApproval }
                guard prior.policyFingerprint == policy else { throw AuthorizationError.stalePolicy }
                guard now >= prior.updatedAt else { throw AuthorizationError.clockRegression }
                return try expireIfNeeded(prior, at: now)
            }
            return try insert(action, requesterID: requesterID, policy: policy, id: id, at: now, expiresAt: expiresAt)
        }
    }
    public func review(_ id: UUID, action: PolicyAction, policy: ActionFingerprint, requesterID: UUID, reviewerID: UUID, reviewerRevision: UUID,
                       approve: Bool, expectedSequence: Int64, at now: Date) throws -> ApprovalRecord {
        try validate(action)
        return try database.transaction {
            let prior = try checked(id, action: action, policy: policy, sequence: expectedSequence, now: now)
            guard prior.requesterID == requesterID else { throw AuthorizationError.invalidApproval }
            let fresh = try expireIfNeeded(prior, at: now)
            guard fresh.state != .expired else { return fresh }
            guard fresh.state == .pending else { throw AuthorizationError.alreadyUsed }
            return try transition(fresh, to: approve ? .approved : .rejected, reviewerID: reviewerID, reviewerRevision: reviewerRevision, at: now)
        }
    }
    public func consume(_ id: UUID, action: PolicyAction, policy: ActionFingerprint, requesterID: UUID,
                        expectedSequence: Int64, at now: Date) throws -> ApprovalRecord {
        try validate(action)
        return try database.transaction {
            let prior = try checked(id, action: action, policy: policy, sequence: expectedSequence, now: now)
            guard prior.requesterID == requesterID else { throw AuthorizationError.invalidApproval }
            let fresh = try expireIfNeeded(prior, at: now)
            guard fresh.state != .expired else { return fresh }
            guard fresh.state == .approved else { throw fresh.state == .pending ? AuthorizationError.approvalRequired : AuthorizationError.alreadyUsed }
            return try transition(fresh, to: .consumed, reviewerID: fresh.reviewerID, reviewerRevision: fresh.reviewerRevision, at: now)
        }
    }
    /// Both the immutable original and the newly reviewed payload survive a modify-and-approve action.
    public func replace(_ id: UUID, original: PolicyAction, replacement: PolicyAction, requesterID: UUID,
                        originalPolicy: ActionFingerprint, replacementPolicy: ActionFingerprint, reviewerID: UUID, reviewerRevision: UUID,
                        expectedSequence: Int64, at now: Date, expiresAt: Date) throws -> ApprovalRecord {
        try validate(original); try validate(replacement)
        guard original.id != replacement.id else { throw AuthorizationError.invalidApproval }
        return try database.transaction {
            let prior = try checked(id, action: original, policy: originalPolicy, sequence: expectedSequence, now: now)
            guard prior.requesterID == requesterID else { throw AuthorizationError.invalidApproval }
            let fresh = try expireIfNeeded(prior, at: now)
            guard fresh.state != .expired else { return fresh }
            guard [.pending, .approved].contains(fresh.state), try byAction(replacement.id) == nil else { throw AuthorizationError.alreadyUsed }
            _ = try transition(fresh, to: .modified, reviewerID: reviewerID, reviewerRevision: reviewerRevision, at: now)
            let prepared = try insert(replacement, requesterID: requesterID, policy: replacementPolicy, id: UUID(), at: now, expiresAt: expiresAt)
            return try transition(prepared, to: .approved, reviewerID: reviewerID, reviewerRevision: reviewerRevision, at: now)
        }
    }
    public func events(for id: UUID, after sequence: Int64 = 0, limit: Int = 100) throws -> [ApprovalEvent] {
        guard sequence >= 0, (1...1_000).contains(limit) else { throw AuthorizationError.invalidInput }
        return try database.query("""
            SELECT sequence,state,recorded_at,reviewer_id,reviewer_revision FROM approval_events
            WHERE workspace_id=? AND project_id=? AND environment_id=? AND approval_id=? AND sequence>?
            ORDER BY sequence LIMIT ?
            """, context + [.text(id.uuidString), .integer(sequence), .integer(Int64(limit))]) { statement in
            let sequence = sqlite3_column_int64(statement, 0), time = sqlite3_column_double(statement, 2)
            guard sequence > 0, let state = ApprovalState(rawValue: try SQLiteConnection.text(statement, 1)), time.isFinite else { throw OperationalStoreError.invalidDatabase }
            return ApprovalEvent(approvalID: id, scope: scope, environmentID: environmentID, sequence: sequence, state: state,
                                 recordedAt: Date(timeIntervalSince1970: time), reviewerID: try Self.optionalID(statement, 3), reviewerRevision: try Self.optionalID(statement, 4))
        }
    }
    private func validate(_ action: PolicyAction) throws {
        try Task.checkCancellation(); try action.validate()
        guard action.scope == scope, action.environmentID == environmentID else { throw AuthorizationError.scopeMismatch }
    }
    private func checked(_ id: UUID, action: PolicyAction, policy: ActionFingerprint, sequence: Int64, now: Date) throws -> ApprovalRecord {
        guard now.timeIntervalSince1970.isFinite, sequence > 0, sequence < Int64.max else { throw AuthorizationError.invalidInput }
        guard let prior = try load(id) else { throw AuthorizationError.missingApproval }
        guard prior.sequence == sequence else { throw AuthorizationError.staleSequence }
        guard prior.action == action else { throw AuthorizationError.invalidApproval }
        guard prior.policyFingerprint == policy else { throw AuthorizationError.stalePolicy }
        guard now >= prior.updatedAt else { throw AuthorizationError.clockRegression }
        return prior
    }
    private func expireIfNeeded(_ record: ApprovalRecord, at now: Date) throws -> ApprovalRecord {
        guard now.timeIntervalSince1970.isFinite else { throw AuthorizationError.invalidInput }
        if [.pending, .approved].contains(record.state), now >= record.expiresAt {
            return try transition(record, to: .expired, reviewerID: record.reviewerID, reviewerRevision: record.reviewerRevision, at: now)
        }
        return record
    }
    private func insert(_ action: PolicyAction, requesterID: UUID, policy: ActionFingerprint, id: UUID,
                        at now: Date, expiresAt: Date) throws -> ApprovalRecord {
        let record = try ApprovalRecord(id: id, action: action, requesterID: requesterID, policyFingerprint: policy,
            state: .pending, sequence: 1, createdAt: now, expiresAt: expiresAt, updatedAt: now, reviewerID: nil, reviewerRevision: nil)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let bytes = try encoder.encode(action); guard bytes.count <= 8_192 else { throw AuthorizationError.invalidInput }
        try database.execute("INSERT INTO approvals VALUES (?,?,?,?,?,?,?,?, 'pending',1,?,?,?,NULL,NULL)",
            context + [.text(id.uuidString), .text(action.id.uuidString), .text(String(decoding: bytes, as: UTF8.self)),
                       .text(requesterID.uuidString), .text(policy.rawValue), .real(now.timeIntervalSince1970),
                       .real(expiresAt.timeIntervalSince1970), .real(now.timeIntervalSince1970)])
        try appendEvent(record)
        return record
    }
    private func transition(_ prior: ApprovalRecord, to state: ApprovalState, reviewerID: UUID?, reviewerRevision: UUID?, at now: Date) throws -> ApprovalRecord {
        let next = try ApprovalRecord(id: prior.id, action: prior.action, requesterID: prior.requesterID, policyFingerprint: prior.policyFingerprint,
            state: state, sequence: prior.sequence + 1, createdAt: prior.createdAt, expiresAt: prior.expiresAt, updatedAt: now, reviewerID: reviewerID, reviewerRevision: reviewerRevision)
        let reviewer = reviewerID?.uuidString ?? ""
        try database.execute("""
            UPDATE approvals SET state=?,sequence=?,updated_at=?,reviewer_id=NULLIF(?,''),reviewer_revision=NULLIF(?,'')
            WHERE workspace_id=? AND project_id=? AND environment_id=? AND approval_id=? AND sequence=?
            """, [.text(state.rawValue), .integer(next.sequence), .real(now.timeIntervalSince1970), .text(reviewer), .text(reviewerRevision?.uuidString ?? "")] + context + [.text(prior.id.uuidString), .integer(prior.sequence)])
        guard try database.integer("SELECT changes()") == 1 else { throw AuthorizationError.staleSequence }
        try appendEvent(next); return next
    }
    private func appendEvent(_ record: ApprovalRecord) throws {
        try database.execute("INSERT INTO approval_events VALUES (?,?,?,?,?,?,?,NULLIF(?,''),NULLIF(?,''))", context + [
            .text(record.id.uuidString), .integer(record.sequence), .text(record.state.rawValue),
            .real(record.updatedAt.timeIntervalSince1970), .text(record.reviewerID?.uuidString ?? ""), .text(record.reviewerRevision?.uuidString ?? "")])
    }
    private static let select = "SELECT approval_id,action_id,action_json,requester_id,policy_fingerprint,state,sequence,created_at,expires_at,updated_at,reviewer_id,reviewer_revision FROM approvals"
    private func load(_ id: UUID) throws -> ApprovalRecord? {
        try database.query(Self.select + " WHERE workspace_id=? AND project_id=? AND environment_id=? AND approval_id=?",
                           context + [.text(id.uuidString)], map: decode).first
    }
    private func byAction(_ id: UUID) throws -> ApprovalRecord? {
        try database.query(Self.select + " WHERE workspace_id=? AND project_id=? AND environment_id=? AND action_id=?",
                           context + [.text(id.uuidString)], map: decode).first
    }
    private func decode(_ s: OpaquePointer) throws -> ApprovalRecord {
        do {
            guard let id = UUID(uuidString: try SQLiteConnection.text(s, 0)), let actionID = UUID(uuidString: try SQLiteConnection.text(s, 1)),
                  let requester = UUID(uuidString: try SQLiteConnection.text(s, 3)), let policy = ActionFingerprint(rawValue: try SQLiteConnection.text(s, 4)),
                  let state = ApprovalState(rawValue: try SQLiteConnection.text(s, 5)) else { throw OperationalStoreError.invalidDatabase }
            let action = try JSONDecoder().decode(PolicyAction.self, from: Data(SQLiteConnection.text(s, 2, maximumBytes: 8_192).utf8))
            guard action.id == actionID, action.scope == scope, action.environmentID == environmentID else { throw OperationalStoreError.invalidDatabase }
            return try ApprovalRecord(id: id, action: action, requesterID: requester, policyFingerprint: policy, state: state,
                sequence: sqlite3_column_int64(s, 6), createdAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 7)),
                expiresAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 8)), updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(s, 9)),
                reviewerID: Self.optionalID(s, 10), reviewerRevision: Self.optionalID(s, 11))
        } catch { throw OperationalStoreError.invalidDatabase }
    }
    private static func optionalID(_ s: OpaquePointer, _ index: Int32) throws -> UUID? {
        if sqlite3_column_type(s, index) == SQLITE_NULL { return nil }
        guard let value = UUID(uuidString: try SQLiteConnection.text(s, index)) else { throw OperationalStoreError.invalidDatabase }
        return value
    }
}
