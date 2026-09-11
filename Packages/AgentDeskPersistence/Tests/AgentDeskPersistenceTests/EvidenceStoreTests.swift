import AgentDeskCore
import AgentDeskSecurity
import Darwin
import Foundation
import SQLite3
import XCTest
@testable import AgentDeskPersistence

@MainActor
final class EvidenceStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let context = RedactionContext(scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
        let agentID = AgentID()
        var location: URL { root.appendingPathComponent("operations.sqlite") }
        var directory: URL {
            ["Evidence", context.scope.workspaceID.rawValue, context.scope.projectID.rawValue, context.environmentID.rawValue, context.runID.rawValue]
                .reduce(root) { $0.appendingPathComponent($1) }
        }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
        func store() throws -> EvidenceStore { try EvidenceStore(database: location, context: context, agentID: agentID) }
        func operational() throws -> OperationalStore { try OperationalStore(database: location, workspaceID: context.scope.workspaceID) }
        func text(_ text: String = "password=synthetic-evidence-secret") throws -> RedactedText {
            try ContentRedactor(context: context).redactText(text, in: context)
        }
        func fingerprint() throws -> ActionFingerprint { try ActionFingerprint(bytes: Data("synthetic execution configuration".utf8)) }
        func ready() async throws -> EvidenceStore {
            _ = try await operational().createRun(in: context.scope, id: context.runID, at: Date(timeIntervalSince1970: 10))
            let store = try store()
            _ = try await store.register(snapshot: text("environment=synthetic-test"), agentRevision: 1, configurationFingerprint: fingerprint())
            return store
        }
        func file(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".txt") }
        func assertSecretAbsent() throws {
            let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let file as URL in enumerator where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                XCTAssertNil(try Data(contentsOf: file).range(of: Data("synthetic-evidence-secret".utf8)))
            }
        }
    }
    private let date = Date(timeIntervalSince1970: 20)

    func testRedactedTraceArtifactProvenancePaginationAndSnapshotSurviveReopen() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try await fixture.ready(), content = try fixture.text()
        let trace = try await store.appendTrace(content, source: .providerCommand, basis: .observed, at: date)
        let artifact = try await store.publishArtifact(content, kind: .output, source: .providerResponse, basis: .interpretation, at: date)
        let reopened = try fixture.store()
        let binding = try await reopened.binding(); XCTAssertEqual(binding?.context, fixture.context); XCTAssertEqual(binding?.agentID, fixture.agentID)
        let page = try await reopened.records(limit: 1); XCTAssertEqual(page, [trace])
        let next = try await reopened.records(after: trace.sequence); XCTAssertEqual(next, [artifact])
        let savedTrace = try await reopened.trace(trace.id), savedArtifact = try await reopened.artifact(artifact.id)
        XCTAssertEqual(savedTrace?.content.text, content.text); XCTAssertEqual(savedArtifact?.text, content.text)
        XCTAssertEqual(savedArtifact?.classification, .confidential); XCTAssertEqual(artifact.basis, .interpretation)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: fixture.file(artifact.id).path)[.posixPermissions] as? Int, 0o600)
        let report = try await reopened.recover(); XCTAssertTrue(report.unavailable.isEmpty); XCTAssertTrue(report.orphanIDs.isEmpty)
        // Search actual SQLite, journal and artifact bytes, not just the returned representation.
        try fixture.assertSecretAbsent()
    }
    func testForeignContextsAndAgentsCannotReadOrPublishBoundEvidence() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try await fixture.ready()
        let contexts = [RedactionContext(scope: ProjectScope(workspaceID: WorkspaceID(), projectID: fixture.context.scope.projectID), environmentID: fixture.context.environmentID, runID: fixture.context.runID),
                        RedactionContext(scope: ProjectScope(workspaceID: fixture.context.scope.workspaceID, projectID: ProjectID()), environmentID: fixture.context.environmentID, runID: fixture.context.runID),
                        RedactionContext(scope: fixture.context.scope, environmentID: EnvironmentID(), runID: fixture.context.runID),
                        RedactionContext(scope: fixture.context.scope, environmentID: fixture.context.environmentID, runID: RunID())]
        for context in contexts {
            let content = try ContentRedactor(context: context).redactText("foreign", in: context)
            do { _ = try await store.appendTrace(content, source: .runtime, basis: .observed, at: date); XCTFail() }
            catch { XCTAssertEqual(error as? OperationalStoreError, .scopeMismatch) }
            let foreign = try EvidenceStore(database: fixture.location, context: context, agentID: fixture.agentID)
            do { _ = try await foreign.records(); XCTFail() }
            catch { XCTAssertTrue(error as? OperationalStoreError == .scopeMismatch || error as? EvidenceStoreError == .unregisteredRun) }
        }
        let foreignAgent = try EvidenceStore(database: fixture.location, context: fixture.context, agentID: AgentID())
        do { _ = try await foreignAgent.binding(); XCTFail() } catch { XCTAssertEqual(error as? OperationalStoreError, .scopeMismatch) }
        let records = try await store.records(); XCTAssertTrue(records.isEmpty)
    }
    func testRegistrationFreezesIdentityAndSnapshotBeforeExecution() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try fixture.store()
        do { _ = try await store.register(snapshot: fixture.text(), agentRevision: 1, configurationFingerprint: fixture.fingerprint()); XCTFail() }
        catch { XCTAssertEqual(error as? OperationalStoreError, .missingRun) }
        _ = try await fixture.operational().createRun(in: fixture.context.scope, id: fixture.context.runID, at: Date(timeIntervalSince1970: 10))
        do { _ = try await store.appendTrace(fixture.text(), source: .runtime, basis: .observed, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .unregisteredRun) }
        let binding = try await store.register(snapshot: fixture.text(), agentRevision: 1, configurationFingerprint: fixture.fingerprint())
        _ = try await fixture.operational().recordState(.running, for: fixture.context.runID, in: fixture.context.scope, expectedSequence: 1, at: date)
        let again = try await store.register(snapshot: fixture.text(), agentRevision: 1, configurationFingerprint: fixture.fingerprint()); XCTAssertEqual(again, binding)
        do { _ = try await store.register(snapshot: fixture.text("changed"), agentRevision: 1, configurationFingerprint: fixture.fingerprint()); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .conflictingBinding) }
        let other = try Fixture(); defer { other.cleanup() }
        _ = try await other.operational().createRun(in: other.context.scope, id: other.context.runID)
        _ = try await other.operational().recordState(.running, for: other.context.runID, in: other.context.scope, expectedSequence: 1)
        do { _ = try await other.store().register(snapshot: other.text(), agentRevision: 1, configurationFingerprint: other.fingerprint()); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .conflictingBinding) }
    }
    func testRetriesAcrossConnectionsAreIdempotentAndRejectChangedEvidence() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let first = try await fixture.ready(), second = try fixture.store(), id = UUID(), content = try fixture.text(), date = date
        async let one = first.publishArtifact(content, kind: .command, source: .providerCommand, basis: .observed, id: id, at: date)
        async let two = second.publishArtifact(content, kind: .command, source: .providerCommand, basis: .observed, id: id, at: date)
        let results = try await (one, two); XCTAssertEqual(results.0, results.1)
        let records = try await second.records(); XCTAssertEqual(records.count, 1)
        do { _ = try await first.publishArtifact(fixture.text("different"), kind: .command, source: .providerCommand, basis: .observed, id: id, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .conflictingRecord) }
        do { _ = try await first.publishArtifact(content, kind: .output, source: .providerResponse, basis: .interpretation, id: id, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .conflictingRecord) }
        XCTAssertEqual(try String(contentsOf: fixture.file(id), encoding: .utf8), content.text)
    }
    func testFailedMetadataCommitLeavesAnUnpublishedOrphanThatExactRetryAdopts() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try await fixture.ready(), connection = try SQLiteConnection(database: fixture.location), id = UUID(), content = try fixture.text()
        try connection.execute("CREATE TRIGGER evidence_failure BEFORE INSERT ON evidence_items BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        do { _ = try await store.publishArtifact(content, kind: .output, source: .runtime, basis: .observed, id: id, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? OperationalStoreError, .database(SQLITE_CONSTRAINT)) }
        XCTAssertEqual(try connection.integer("SELECT COUNT(*) FROM evidence_items"), 0)
        let reopened = try fixture.store(), unavailable = try await reopened.artifact(id); XCTAssertNil(unavailable)
        let before = try await reopened.recover(); XCTAssertEqual(before.orphanIDs, [id]); XCTAssertTrue(before.unavailable.isEmpty)
        try connection.execute("DROP TRIGGER evidence_failure")
        let accepted = try await reopened.publishArtifact(content, kind: .output, source: .runtime, basis: .observed, id: id, at: date)
        XCTAssertEqual(accepted.sequence, 1)
        let after = try await reopened.recover(); XCTAssertTrue(after.orphanIDs.isEmpty)
    }
    func testMissingArtifactsCanBeRepairedButCorruptFilesArePreservedAndNeverReturned() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try await fixture.ready(), content = try fixture.text()
        let missing = try await store.publishArtifact(content, kind: .output, source: .runtime, basis: .observed, at: date)
        let corrupt = try await store.publishArtifact(content, kind: .diff, source: .repository, basis: .observed, at: date)
        try FileManager.default.removeItem(at: fixture.file(missing.id))
        try Data("untrusted-corruption".utf8).write(to: fixture.file(corrupt.id))
        let reopened = try fixture.store(), report = try await reopened.recover()
        XCTAssertEqual(report.unavailable, [.init(id: missing.id, reason: .missing), .init(id: corrupt.id, reason: .corrupt)])
        do { _ = try await reopened.artifact(corrupt.id); XCTFail() } catch { XCTAssertEqual(error as? EvidenceStoreError, .corruptArtifact) }
        _ = try await fixture.operational().recordState(.failed, for: fixture.context.runID, in: fixture.context.scope, expectedSequence: 1, at: date)
        let repaired = try await reopened.publishArtifact(content, kind: .output, source: .runtime, basis: .observed, id: missing.id, at: date)
        XCTAssertEqual(repaired, missing)
        do { _ = try await reopened.publishArtifact(content, kind: .diff, source: .repository, basis: .observed, id: corrupt.id, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .conflictingRecord) }
        XCTAssertEqual(try String(contentsOf: fixture.file(corrupt.id), encoding: .utf8), "untrusted-corruption")
        do { _ = try await reopened.appendTrace(content, source: .runtime, basis: .observed, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .invalidInput) }
    }
    func testSymlinkHardlinkSpecialFilesAndForeignDirectoryCannotEscapeStorage() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try await fixture.ready(), target = fixture.root.appendingPathComponent("synthetic-foreign.txt")
        try Data("foreign data".utf8).write(to: target)
        for mode in 0..<3 {
            let record = try await store.publishArtifact(fixture.text(), kind: .output, source: .runtime, basis: .observed, at: date)
            try FileManager.default.removeItem(at: fixture.file(record.id))
            switch mode {
            case 0: try FileManager.default.createSymbolicLink(at: fixture.file(record.id), withDestinationURL: target)
            case 1: try FileManager.default.linkItem(at: target, to: fixture.file(record.id))
            default: XCTAssertEqual(mkfifo(fixture.file(record.id).path, 0o600), 0)
            }
            do { _ = try await store.artifact(record.id); XCTFail() } catch { XCTAssertEqual(error as? EvidenceStoreError, .unsafeFile) }
        }
        let report = try await store.recover(); XCTAssertEqual(report.unavailable.count, 3); XCTAssertTrue(report.unavailable.allSatisfy { $0.reason == .unsafe })
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "foreign data")
        let other = try Fixture(); defer { other.cleanup() }
        let otherStore = try await other.ready()
        try FileManager.default.createSymbolicLink(at: other.root.appendingPathComponent("Evidence"), withDestinationURL: fixture.root)
        do { _ = try await otherStore.publishArtifact(other.text(), kind: .output, source: .runtime, basis: .observed, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .unsafeFile) }
        let records = try await otherStore.records(); XCTAssertTrue(records.isEmpty)
    }
    func testTraceFailureCancellationBoundsAndProvenanceDoNotPublishPartialRecords() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try await fixture.ready(), connection = try SQLiteConnection(database: fixture.location)
        try connection.execute("CREATE TRIGGER trace_failure BEFORE INSERT ON evidence_items BEGIN SELECT RAISE(ABORT, 'synthetic failure'); END")
        do { _ = try await store.appendTrace(fixture.text(), source: .runtime, basis: .observed, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? OperationalStoreError, .database(SQLITE_CONSTRAINT)) }
        try connection.execute("DROP TRIGGER trace_failure")
        let text = try fixture.text(), date = date
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; return try await store.appendTrace(text, source: .runtime, basis: .observed, at: date) }
        do { _ = try await cancelled.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await store.appendTrace(text, source: .providerResponse, basis: .observed, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .invalidInput) }
        let large = try fixture.text(String(repeating: "x", count: 65_537))
        do { _ = try await store.appendTrace(large, source: .runtime, basis: .observed, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .invalidInput) }
        let records = try await store.records(); XCTAssertTrue(records.isEmpty)
        let artifact = try await store.publishArtifact(large, kind: .output, source: .runtime, basis: .observed, at: date)
        XCTAssertEqual(artifact.byteCount, 65_537)
        do { _ = try await store.appendTrace(text, source: .runtime, basis: .observed, at: Date(timeIntervalSince1970: 19)); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .invalidInput) }
    }
    func testForeignMetadataAndChangedTraceBytesFailClosed() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try await fixture.ready(), connection = try SQLiteConnection(database: fixture.location)
        let record = try await store.appendTrace(fixture.text(), source: .runtime, basis: .observed, at: date)
        try connection.execute("UPDATE evidence_items SET body='untrusted replacement'")
        do { _ = try await store.trace(record.id); XCTFail() } catch { XCTAssertEqual(error as? OperationalStoreError, .invalidDatabase) }
        try connection.execute("UPDATE evidence_items SET body=?", [.text(fixture.text().text)])
        let foreign = RedactionContext(scope: fixture.context.scope, environmentID: EnvironmentID(), runID: fixture.context.runID)
        let copied = EvidenceRecord(id: record.id, context: foreign, agentID: record.agentID, sequence: record.sequence, kind: record.kind,
            source: record.source, basis: record.basis, format: record.format, classification: record.classification, redactionCount: record.redactionCount,
            policyVersion: record.policyVersion, fingerprint: record.fingerprint, byteCount: record.byteCount, recordedAt: record.recordedAt)
        try connection.execute("UPDATE evidence_items SET metadata_json=?", [.json(String(decoding: JSONEncoder().encode(copied), as: UTF8.self))])
        do { _ = try await store.records(); XCTFail() } catch { XCTAssertEqual(error as? OperationalStoreError, .invalidDatabase) }
    }
    func testVersionFourMigrationPreservesRunsAndFailedMigrationDoesNotAdvance() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let connection = try SQLiteConnection(database: fixture.location)
        for statement in OperationalMigrations.versionOne + OperationalMigrations.versionTwo + OperationalMigrations.versionThree + OperationalMigrations.versionFour {
            try connection.execute(statement)
        }
        try connection.execute("PRAGMA application_id=\(OperationalMigrations.applicationID)"); try connection.execute("PRAGMA user_version=4")
        try connection.execute("INSERT INTO runs VALUES (?, ?, ?, 10, 'queued')", [.text(fixture.context.scope.workspaceID.rawValue), .text(fixture.context.scope.projectID.rawValue), .text(fixture.context.runID.rawValue)])
        try connection.execute("CREATE TABLE evidence_items (synthetic_collision TEXT)")
        XCTAssertThrowsError(try fixture.store()); XCTAssertEqual(try connection.integer("PRAGMA user_version"), 4)
        XCTAssertEqual(try connection.integer("SELECT COUNT(*) FROM sqlite_master WHERE name='evidence_runs'"), 0)
        XCTAssertEqual(try connection.integer("SELECT COUNT(*) FROM runs"), 1)
        try connection.execute("DROP TABLE evidence_items")
        let store = try fixture.store(); XCTAssertEqual(try connection.integer("PRAGMA user_version"), 7)
        let binding = try await store.binding(); XCTAssertNil(binding)
        _ = try await store.register(snapshot: fixture.text(), agentRevision: 1, configurationFingerprint: fixture.fingerprint())
    }
    func testRecoveryReportsStagedAndUnexpectedFilesWithoutPublishingTheirNamesOrContents() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try await fixture.ready()
        _ = try await store.recover()
        try Data("private unfinished bytes".utf8).write(to: fixture.directory.appendingPathComponent(".stage-\(UUID().uuidString)"))
        try Data("unrelated preserved bytes".utf8).write(to: fixture.directory.appendingPathComponent("synthetic-private-name"))
        let report = try await store.recover()
        XCTAssertEqual(report.stagedFileCount, 1); XCTAssertEqual(report.unexpectedFileCount, 1); XCTAssertTrue(report.orphanIDs.isEmpty)
        XCTAssertFalse(String(describing: report).contains("private"))
        let records = try await store.records(); XCTAssertTrue(records.isEmpty)
    }
    func testCapacityIsEnforcedBeforeCreatingFilesAndExactRetriesStillWork() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try await fixture.ready(), content = try fixture.text("public trace"), connection = try SQLiteConnection(database: fixture.location)
        let first = try await store.appendTrace(content, source: .runtime, basis: .observed, at: date)
        // Seed valid durable history in one transaction, without thousands of per-record fsyncs.
        try connection.transaction {
            for sequence in 2...4_096 {
                let record = EvidenceRecord(id: UUID(), context: first.context, agentID: first.agentID, sequence: Int64(sequence), kind: first.kind,
                    source: first.source, basis: first.basis, format: first.format, classification: first.classification, redactionCount: first.redactionCount,
                    policyVersion: first.policyVersion, fingerprint: first.fingerprint, byteCount: first.byteCount, recordedAt: first.recordedAt)
                try connection.execute("INSERT INTO evidence_items VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    [.text(fixture.context.scope.workspaceID.rawValue), .text(fixture.context.scope.projectID.rawValue), .text(fixture.context.runID.rawValue),
                     .text(fixture.context.environmentID.rawValue), .text(record.id.uuidString.lowercased()), .integer(record.sequence),
                     .json(String(decoding: JSONEncoder().encode(record), as: UTF8.self)), .text(content.text)])
            }
        }
        do { _ = try await store.publishArtifact(content, kind: .output, source: .runtime, basis: .observed, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .invalidInput) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.path))
        let retry = try await store.appendTrace(content, source: .runtime, basis: .observed, id: first.id, at: date); XCTAssertEqual(retry, first)
        let page = try await store.records(after: 4_095); XCTAssertEqual(page.map(\.sequence), [4_096])
    }
    func testFilePermissionFailureAndConflictingOrphanNeverPublishMetadataOrOverwriteBytes() async throws {
        let fixture = try Fixture(); defer { fixture.cleanup() }
        let store = try await fixture.ready(), id = UUID()
        _ = try await store.recover()
        XCTAssertEqual(chmod(fixture.directory.path, 0o500), 0)
        defer { chmod(fixture.directory.path, 0o700) }
        do { _ = try await store.publishArtifact(fixture.text(), kind: .output, source: .runtime, basis: .observed, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .fileSystem(EACCES)) }
        XCTAssertEqual(chmod(fixture.directory.path, 0o700), 0)
        try Data("preserved orphan bytes".utf8).write(to: fixture.file(id))
        do { _ = try await store.publishArtifact(fixture.text(), kind: .output, source: .runtime, basis: .observed, id: id, at: date); XCTFail() }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .conflictingRecord) }
        XCTAssertEqual(try String(contentsOf: fixture.file(id), encoding: .utf8), "preserved orphan bytes")
        let records = try await store.records(); XCTAssertTrue(records.isEmpty)
    }
}
