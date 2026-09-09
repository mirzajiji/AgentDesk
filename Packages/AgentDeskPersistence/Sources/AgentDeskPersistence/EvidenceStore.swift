import AgentDeskCore
import AgentDeskSecurity
import Foundation
import SQLite3

/// Lower-level persistence for an already authorized run. The coordinator owns policy and identity selection.
/// All untrusted text enters as RedactedText; no raw filename, SQL, provider chunk or secret is accepted.
public actor EvidenceStore {
    public nonisolated let context: RedactionContext
    public nonisolated let agentID: AgentID
    private let database: SQLiteConnection
    private let container: URL
    private var files: ArtifactFiles?
    private var runKeys: [SQLValue] {
        [.text(context.scope.workspaceID.rawValue), .text(context.scope.projectID.rawValue), .text(context.runID.rawValue)]
    }
    private var keys: [SQLValue] { runKeys + [.text(context.environmentID.rawValue)] }
    private static let predicate = "workspace_id=? AND project_id=? AND run_id=? AND environment_id=?"
    private static let select = "SELECT evidence_id, sequence, metadata_json, body FROM evidence_items WHERE " + predicate

    public init(database location: URL, context: RedactionContext, agentID: AgentID) throws {
        let connection = try SQLiteConnection(database: location)
        try OperationalMigrations.apply(to: connection)
        database = connection; container = location.deletingLastPathComponent()
        self.context = context; self.agentID = agentID
    }

    /// Registration is immutable, idempotent and permitted only while a previously unbound run is queued.
    public func register(snapshot: RedactedText, agentRevision: Int,
                         configurationFingerprint: ActionFingerprint) throws -> EvidenceRunBinding {
        try check(snapshot)
        let binding = EvidenceRunBinding(context: context, agentID: agentID, agentRevision: agentRevision,
                                         configurationFingerprint: configurationFingerprint, snapshot: StoredEvidenceContent(snapshot))
        try binding.validate()
        let json = try encode(binding, maximumBytes: 131_072)
        return try database.transaction {
            if let existing = try loadBinding() {
                guard existing == binding else { throw EvidenceStoreError.conflictingBinding }
                return existing
            }
            let run = try runState()
            guard run.state == .queued else { throw EvidenceStoreError.conflictingBinding }
            try database.execute("INSERT INTO evidence_runs VALUES (?, ?, ?, ?, ?)", keys + [.json(json)])
            return binding
        }
    }
    public func binding() throws -> EvidenceRunBinding? { try loadBinding() }

    /// IDs are caller-retained retry keys. Reusing an ID with different content/provenance fails.
    public func appendTrace(_ content: RedactedText, source: EvidenceSource, basis: EvidenceBasis,
                            format: EvidenceFormat = .text, id: UUID = UUID(), at date: Date = Date()) throws -> EvidenceRecord {
        try publish(content, kind: .trace, source: source, basis: basis, format: format, id: id, date: date)
    }
    public func publishArtifact(_ content: RedactedText, kind: EvidenceKind, source: EvidenceSource, basis: EvidenceBasis,
                                format: EvidenceFormat = .text, id: UUID = UUID(), at date: Date = Date()) throws -> EvidenceRecord {
        guard kind != .trace else { throw EvidenceStoreError.invalidInput }
        return try publish(content, kind: kind, source: source, basis: basis, format: format, id: id, date: date)
    }

    public func records(after sequence: Int64 = 0, limit: Int = 100) throws -> [EvidenceRecord] {
        try requireBinding()
        guard sequence >= 0, (1...256).contains(limit) else { throw EvidenceStoreError.invalidInput }
        return try database.query(Self.select + " AND sequence>? ORDER BY sequence LIMIT ?",
                                  keys + [.integer(sequence), .integer(Int64(limit))], map: decode).map(\.record)
    }
    public func trace(_ id: UUID) throws -> StoredTrace? {
        try requireBinding()
        guard let item = try load(id) else { return nil }
        guard item.record.kind == .trace, let content = item.content else { throw EvidenceStoreError.invalidInput }
        return StoredTrace(record: item.record, content: content)
    }
    public func artifact(_ id: UUID) throws -> StoredEvidenceContent? {
        try requireBinding()
        guard let item = try load(id) else { return nil }
        guard item.record.kind != .trace else { throw EvidenceStoreError.invalidInput }
        return try readArtifact(item.record)
    }

    /// Reports durable metadata with unavailable files and unpublished orphans. It never deletes evidence.
    /// Retrying the original publication repairs a missing file or adopts an exact orphan transactionally.
    public func recover() throws -> EvidenceRecoveryReport {
        try requireBinding()
        return try database.transaction {
            let records = try database.query(Self.select + " ORDER BY sequence LIMIT 4097", keys, map: decode).map(\.record)
            guard records.count <= 4_096 else { throw OperationalStoreError.invalidDatabase }
            var unavailable: [ArtifactRecoveryIssue] = []
            let artifacts = records.filter { $0.kind != .trace }
            for record in artifacts {
                do { _ = try readArtifact(record) }
                catch EvidenceStoreError.missingArtifact { unavailable.append(.init(id: record.id, reason: .missing)) }
                catch EvidenceStoreError.corruptArtifact { unavailable.append(.init(id: record.id, reason: .corrupt)) }
                catch EvidenceStoreError.unsafeFile { unavailable.append(.init(id: record.id, reason: .unsafe)) }
            }
            let inventory = try artifactFiles().inventory(), published = Set(artifacts.map(\.id))
            return EvidenceRecoveryReport(unavailable: unavailable, orphanIDs: inventory.ids.filter { !published.contains($0) },
                                          stagedFileCount: inventory.staged, unexpectedFileCount: inventory.unexpected)
        }
    }

    private func publish(_ content: RedactedText, kind: EvidenceKind, source: EvidenceSource, basis: EvidenceBasis,
                         format: EvidenceFormat, id: UUID, date: Date) throws -> EvidenceRecord {
        try check(content)
        let stored = StoredEvidenceContent(content)
        try stored.validate(maximumBytes: kind == .trace ? 65_536 : 1_048_576)
        let bytes = Data(content.text.utf8), fingerprint = try ActionFingerprint(bytes: bytes)
        let timestamp = date.timeIntervalSince1970
        guard timestamp.isFinite, timestamp >= 0 else { throw EvidenceStoreError.invalidInput }
        let canonicalDate = Date(timeIntervalSince1970: timestamp)
        return try database.transaction {
            try requireBinding()
            let existing = try load(id)
            let priorSequence = try database.query("SELECT MAX(sequence) FROM evidence_items WHERE " + Self.predicate, keys) {
                sqlite3_column_type($0, 0) == SQLITE_NULL ? 0 : sqlite3_column_int64($0, 0)
            }.first ?? 0
            guard priorSequence >= 0, priorSequence <= 4_096 else { throw OperationalStoreError.invalidDatabase }
            let record = EvidenceRecord(id: id, context: context, agentID: agentID, sequence: existing?.record.sequence ?? priorSequence + 1,
                kind: kind, source: source, basis: basis, format: format, classification: content.classification,
                redactionCount: content.redactionCount, policyVersion: content.policyVersion, fingerprint: fingerprint,
                byteCount: bytes.count, recordedAt: canonicalDate)
            try record.validate()
            if let existing {
                guard existing.record == record else { throw EvidenceStoreError.conflictingRecord }
                if kind != .trace { try artifactFiles().publish(bytes, id: id) }
                return existing.record
            }
            let run = try runState()
            guard !run.state.isTerminal, timestamp >= run.createdAt else { throw EvidenceStoreError.invalidInput }
            if priorSequence > 0 {
                guard let previous = try database.query(Self.select + " AND sequence=?", keys + [.integer(priorSequence)], map: decode).first,
                      canonicalDate >= previous.record.recordedAt else { throw EvidenceStoreError.invalidInput }
            }
            let metadata = try encode(record, maximumBytes: 4_096)
            // Publishing the file before committing its metadata means interruption can leave only an orphan,
            // never a successfully committed row pointing at a partially written file.
            if kind != .trace { try artifactFiles().publish(bytes, id: id) }
            let prefix = keys + [.text(id.uuidString.lowercased()), .integer(record.sequence), .json(metadata)]
            if kind == .trace { try database.execute("INSERT INTO evidence_items VALUES (?, ?, ?, ?, ?, ?, ?, ?)", prefix + [.text(content.text)]) }
            else { try database.execute("INSERT INTO evidence_items VALUES (?, ?, ?, ?, ?, ?, ?, NULL)", prefix) }
            return record
        }
    }
    private func check(_ content: RedactedText) throws {
        try Task.checkCancellation()
        guard content.context == context else { throw OperationalStoreError.scopeMismatch }
    }
    private func requireBinding() throws {
        guard try loadBinding() != nil else { throw EvidenceStoreError.unregisteredRun }
    }
    private func loadBinding() throws -> EvidenceRunBinding? {
        let rows = try database.query("SELECT environment_id,binding_json FROM evidence_runs WHERE workspace_id=? AND project_id=? AND run_id=?", runKeys) { statement in
            guard try SQLiteConnection.text(statement, 0) == context.environmentID.rawValue else { throw OperationalStoreError.scopeMismatch }
            do {
                let result = try JSONDecoder().decode(EvidenceRunBinding.self, from: Data(SQLiteConnection.text(statement, 1, maximumBytes: 131_072).utf8))
                try result.validate()
                guard result.context == context, result.agentID == agentID else { throw OperationalStoreError.scopeMismatch }
                return result
            } catch OperationalStoreError.scopeMismatch { throw OperationalStoreError.scopeMismatch }
            catch { throw OperationalStoreError.invalidDatabase }
        }
        guard rows.count <= 1 else { throw OperationalStoreError.invalidDatabase }
        return rows.first
    }
    private func runState() throws -> (state: RunState, createdAt: Double) {
        guard let result = try database.query("SELECT state,created_at FROM runs WHERE workspace_id=? AND project_id=? AND run_id=?", runKeys, map: { statement in
            guard let state = RunState(rawValue: try SQLiteConnection.text(statement, 0)) else { throw OperationalStoreError.invalidDatabase }
            let time = sqlite3_column_double(statement, 1)
            guard time.isFinite, time >= 0 else { throw OperationalStoreError.invalidDatabase }
            return (state, time)
        }).first else { throw OperationalStoreError.missingRun }
        return result
    }
    private func load(_ id: UUID) throws -> (record: EvidenceRecord, content: StoredEvidenceContent?)? {
        try database.query(Self.select + " AND evidence_id=?", keys + [.text(id.uuidString.lowercased())], map: decode).first
    }
    private func decode(_ statement: OpaquePointer) throws -> (record: EvidenceRecord, content: StoredEvidenceContent?) {
        do {
            let record = try JSONDecoder().decode(EvidenceRecord.self, from: Data(SQLiteConnection.text(statement, 2, maximumBytes: 4_096).utf8))
            try record.validate()
            guard record.context == context, record.agentID == agentID,
                  try SQLiteConnection.text(statement, 0) == record.id.uuidString.lowercased(),
                  sqlite3_column_type(statement, 1) == SQLITE_INTEGER, sqlite3_column_int64(statement, 1) == record.sequence else {
                throw OperationalStoreError.invalidDatabase
            }
            if record.kind == .trace {
                let text = try SQLiteConnection.text(statement, 3)
                let content = try verifiedContent(Data(text.utf8), record: record)
                return (record, content)
            }
            guard sqlite3_column_type(statement, 3) == SQLITE_NULL else { throw OperationalStoreError.invalidDatabase }
            return (record, nil)
        } catch is CancellationError { throw CancellationError() }
        catch { throw OperationalStoreError.invalidDatabase }
    }
    private func readArtifact(_ record: EvidenceRecord) throws -> StoredEvidenceContent {
        try verifiedContent(artifactFiles().read(record.id), record: record)
    }
    private func verifiedContent(_ bytes: Data, record: EvidenceRecord) throws -> StoredEvidenceContent {
        guard bytes.count == record.byteCount, try ActionFingerprint(bytes: bytes) == record.fingerprint,
              let text = String(data: bytes, encoding: .utf8) else { throw EvidenceStoreError.corruptArtifact }
        let content = StoredEvidenceContent(text: text, classification: record.classification,
                                            redactionCount: record.redactionCount, policyVersion: record.policyVersion)
        do { try content.validate(maximumBytes: record.kind == .trace ? 65_536 : 1_048_576) }
        catch { throw EvidenceStoreError.corruptArtifact }
        return content
    }
    private func artifactFiles() throws -> ArtifactFiles {
        if let files { return files }
        let created = try ArtifactFiles(container: container, context: context)
        files = created; return created
    }
    private func encode<T: Encodable>(_ value: T, maximumBytes: Int) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= maximumBytes else { throw EvidenceStoreError.limitExceeded }
        return String(decoding: data, as: UTF8.self)
    }
}
