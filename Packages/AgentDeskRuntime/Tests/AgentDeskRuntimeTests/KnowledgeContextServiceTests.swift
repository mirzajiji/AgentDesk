import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class KnowledgeContextServiceTests: XCTestCase {
    struct Fixture: Sendable {
        let root: URL, scope: ProjectScope, memory: ProjectMemoryStore, requirements: ProjectRequirementStore
        let environment = EnvironmentID()
        let index: KnowledgeSearchIndex
        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic context")
            scope = try await catalog.createProject(in: workspace.id, name: "Synthetic project").scope
            memory = try await catalog.memoryStore(in: scope); requirements = try await catalog.requirementStore(in: scope)
            index = try KnowledgeSearchIndex(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environment: environment)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func redactor() throws -> ContentRedactor { try ContentRedactor(context: .init(scope: scope, environmentID: environment, runID: RunID())) }
        func service(search: (any KnowledgeCandidateSearching)? = nil) throws -> KnowledgeContextService {
            try KnowledgeContextService(memory: memory, requirements: requirements, environment: environment, search: search ?? index)
        }
        func record(_ body: String, path: String = "qa/refund", kind: MemoryKind = .confirmed,
                    environments: [EnvironmentID] = []) async throws -> MemoryRecord {
            let draft = MemoryDraft(kind: kind, topic: .testExpectation, title: "Synthetic context", body: body,
                sources: [.init(scope: scope, origin: .interpretation, label: "Synthetic provenance", capturedAt: Date())],
                environmentScope: environments, changeReason: "Reviewed", knowledgePath: KnowledgePath(rawValue: path)!)
            let pending = try await memory.prepare(draft, in: scope)
            return try await memory.publishReviewed(pending, in: scope)
        }
        func rebuild() async throws { _ = try await index.rebuild(memory: memory, requirements: requirements, redactor: redactor()) }
    }
    struct Search: KnowledgeCandidateSearching {
        let page: KnowledgeCandidatePage
        func candidates(for selection: AgentKnowledgeSelection, in scope: ProjectScope, environment: EnvironmentID) async throws -> KnowledgeCandidatePage { page }
    }
    func object(_ prepared: PreparedKnowledgeContext) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(prepared.content.text.utf8)) as? [String: Any])
    }
    func entries(_ prepared: PreparedKnowledgeContext) throws -> [[String: Any]] { try XCTUnwrap(object(prepared)["entries"] as? [[String: Any]]) }

    func testCurrentRedactedContextKeepsExactVersionsAndSanitizedFingerprints() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await f.record("Refund state. password: synthetic-private-38291")
        try await f.rebuild()
        let prepared = try await f.service().prepare(.init(paths: .init(include: ["qa/**"])), redactor: f.redactor())
        let entry = try XCTUnwrap(entries(prepared).first)
        XCTAssertEqual(entry["sourceID"] as? String, "memory/\(record.id)")
        XCTAssertEqual(entry["revision"] as? Int, 1)
        XCTAssertEqual(entry["kind"] as? String, "confirmed")
        let body = try XCTUnwrap(entry["bodyJSON"] as? String)
        XCTAssertTrue(body.contains("interpretation")); XCTAssertTrue(body.contains("Synthetic provenance"))
        XCTAssertFalse(prepared.content.text.contains("synthetic-private-38291"))
        XCTAssertFalse(prepared.content.text.contains(try record.fingerprint.rawValue))
        let fingerprintData = try JSONSerialization.data(withJSONObject: try XCTUnwrap(entry["sanitizedFingerprint"]), options: [.fragmentsAllowed])
        let fingerprint = try JSONDecoder().decode(ActionFingerprint.self, from: fingerprintData)
        XCTAssertEqual(fingerprint, try ActionFingerprint(bytes: Data(body.utf8)))
        try await prepared.validate()
    }

    func testStaleCacheAndRetiredSourcesNeverBecomeInput() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await f.record("Old source text")
        try await f.rebuild()
        var draft = record.content; draft.body = "Changed source text"; draft.changeReason = "Updated"
        let proposal = try await f.memory.prepare(draft, id: record.id, expectedRevision: 1, in: f.scope)
        _ = try await f.memory.publishReviewed(proposal, in: f.scope)
        let stale = try await f.service().prepare(.init(paths: .init(include: ["qa/**"])), redactor: f.redactor())
        XCTAssertTrue(try entries(stale).isEmpty)
        XCTAssertTrue(stale.content.text.contains("stale-index"))
        XCTAssertFalse(stale.content.text.contains("Old source text")); XCTAssertFalse(stale.content.text.contains("Changed source text"))
        draft.disposition = .archived
        let archived = try await f.memory.prepare(draft, id: record.id, expectedRevision: 2, in: f.scope)
        _ = try await f.memory.publishReviewed(archived, in: f.scope)
        let unavailable = try await f.service().prepare(.init(paths: .init(include: ["qa/**"])), redactor: f.redactor())
        XCTAssertTrue(try entries(unavailable).isEmpty); XCTAssertTrue(unavailable.content.text.contains("unavailable"))
    }

    func testUntrustedSearchCannotBypassClassificationsPathsOrEnvironment() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let records = try await [f.record("Private", path: "qa/private/item"), f.record("Uncertain", kind: .note),
                                 f.record("Other environment", environments: [EnvironmentID()])]
        let candidates = try records.map { KnowledgeCandidate(sourceID: "memory/\($0.id)", revision: $0.revision, fingerprint: try $0.fingerprint) }
        let backend = Search(page: .init(scope: f.scope, environment: f.environment, candidates: candidates, hasMore: false))
        let selection = try AgentKnowledgeSelection(paths: .init(include: ["qa/**"], exclude: ["qa/private/**"]))
        let prepared = try await f.service(search: backend).prepare(selection, redactor: f.redactor())
        XCTAssertTrue(try entries(prepared).isEmpty)
        XCTAssertFalse(prepared.content.text.contains("Other environment")); XCTAssertFalse(prepared.content.text.contains("Uncertain"))
    }

    func testForeignSearchResponseAndMalformedCandidateFailClosed() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let selection = try AgentKnowledgeSelection(paths: .init(include: ["**"]))
        let foreign = Search(page: .init(scope: .init(workspaceID: f.scope.workspaceID, projectID: ProjectID()), environment: f.environment, candidates: [], hasMore: false))
        do { _ = try await f.service(search: foreign).prepare(selection, redactor: f.redactor()); XCTFail() }
        catch { XCTAssertEqual(error as? KnowledgeContextError, .scopeMismatch) }
        let invalid = Search(page: .init(scope: f.scope, environment: f.environment,
            candidates: [.init(sourceID: "memory/../../other", revision: 1, fingerprint: try .canonical("fake"))], hasMore: false))
        do { _ = try await f.service(search: invalid).prepare(selection, redactor: f.redactor()); XCTFail() }
        catch { XCTAssertEqual(error as? KnowledgeContextError, .invalidCandidate) }
    }

    func testExplicitNotesKeepInterpretationAndMissingIndexIsNotAnEmptySearch() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let selection = try AgentKnowledgeSelection(paths: .init(include: ["qa/**"]), kinds: [.note, .inbox])
        do { _ = try await f.service().prepare(selection, redactor: f.redactor()); XCTFail() }
        catch { XCTAssertEqual(error as? KnowledgeIndexError, .notBuilt) }
        _ = try await f.record("Unconfirmed synthetic finding", kind: .note)
        _ = try await f.record("Unreviewed synthetic import", path: "qa/inbox", kind: .inbox)
        try await f.rebuild()
        let prepared = try await f.service().prepare(selection, redactor: f.redactor())
        let values = try entries(prepared)
        XCTAssertEqual(Set(values.compactMap { $0["kind"] as? String }), ["note", "inbox"])
        XCTAssertTrue(values.allSatisfy { ($0["bodyJSON"] as? String)?.contains("interpretation") == true })
    }

    func testReviewedSnapshotRejectsSourceChangesBeforeDispatch() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await f.record("Initial")
        try await f.rebuild()
        let prepared = try await f.service().prepare(.init(paths: .init(include: ["qa/**"])), redactor: f.redactor())
        var draft = record.content; draft.body = "Updated"
        let proposal = try await f.memory.prepare(draft, id: record.id, expectedRevision: 1, in: f.scope)
        _ = try await f.memory.publishReviewed(proposal, in: f.scope)
        do { try await prepared.validate(); XCTFail() } catch { XCTAssertEqual(error as? KnowledgeContextError, .staleSources) }
    }

    func testWholePacketObeysByteAndRecordLimitsAndCancellation() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.record(String(repeating: "界", count: 500), path: "qa/a")
        _ = try await f.record("Small record", path: "qa/b")
        try await f.rebuild()
        let tiny = try await f.service().prepare(.init(paths: .init(include: ["qa/**"]), maximumBytes: 1_024), redactor: f.redactor())
        XCTAssertLessThanOrEqual(tiny.content.text.utf8.count, 1_024)
        XCTAssertEqual(try object(tiny)["omittedByLimit"] as? Bool, true)
        let limited = try await f.service().prepare(.init(paths: .init(include: ["qa/**"]), maximumRecords: 1), redactor: f.redactor())
        XCTAssertEqual(try entries(limited).count, 1); XCTAssertEqual(try object(limited)["omittedByLimit"] as? Bool, true)
        let service = try f.service(), redactor = try f.redactor()
        let task = Task { try Task.checkCancellation(); return try await service.prepare(.init(paths: .init(include: ["qa/**"])), redactor: redactor) }
        task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testRelationshipsResolveLatestActiveAndRemainBoundToReviewedTrace() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let id = RequirementID(rawValue: "refund-state")!, subject = TraceabilitySubject(kind: .automatedTest, id: RequirementID(rawValue: "refund-check")!)
        let first = try await f.requirements.prepare(.init(description: "Original", changeReason: "Synthetic", status: .active), id: id, expectedVersion: nil, in: f.scope)
        _ = try await f.requirements.publishReviewed(first, in: f.scope)
        let trace = try await f.requirements.prepareTrace(subject: subject, title: "Synthetic test", environment: f.environment,
            requirements: [.init(id: id)], changeReason: "Reviewed", in: f.scope)
        _ = try await f.requirements.publishReviewedTrace(trace, in: f.scope)
        let next = try await f.requirements.prepare(.init(description: "Current", changeReason: "Synthetic update", status: .active), id: id, expectedVersion: 1, in: f.scope)
        _ = try await f.requirements.publishReviewed(next, in: f.scope)
        try await f.rebuild()
        let selection = try AgentKnowledgeSelection(paths: .init(include: ["requirements/**"]), query: "nonmatching", relationships: [subject])
        let prepared = try await f.service().prepare(selection, redactor: f.redactor())
        XCTAssertEqual(try entries(prepared).first?["revision"] as? Int, 2)
        let archive = try await f.requirements.prepareTrace(subject: subject, title: "Synthetic test", environment: f.environment,
            requirements: [.init(id: id)], changeReason: "Archive", archived: true, expectedRevision: 1, in: f.scope)
        _ = try await f.requirements.publishReviewedTrace(archive, in: f.scope)
        do { try await prepared.validate(); XCTFail() } catch { XCTAssertEqual(error as? KnowledgeContextError, .staleSources) }
    }
}
