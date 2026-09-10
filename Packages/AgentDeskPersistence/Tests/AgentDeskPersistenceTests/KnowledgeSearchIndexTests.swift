import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPersistence

@MainActor
final class KnowledgeSearchIndexTests: XCTestCase {
    private struct Fixture {
        let root: URL, catalog: WorkspaceCatalog, scope: ProjectScope, memory: ProjectMemoryStore, requirements: ProjectRequirementStore
        let environment = EnvironmentID()
        var location: URL { root.appendingPathComponent("operations.sqlite") }
        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic search")
            let project = try await catalog.createProject(in: workspace.id, name: "Synthetic project")
            scope = project.scope
            memory = try await catalog.memoryStore(in: scope); requirements = try await catalog.requirementStore(in: scope)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func redactor(environment: EnvironmentID? = nil) throws -> ContentRedactor {
            try ContentRedactor(context: .init(scope: scope, environmentID: environment ?? self.environment, runID: RunID()))
        }
        func index() throws -> KnowledgeSearchIndex { try KnowledgeSearchIndex(database: location, scope: scope, environment: environment) }
        func record(_ text: String, path: String = "architecture/payments", kind: MemoryKind = .confirmed,
                    environments: [EnvironmentID] = []) async throws -> MemoryRecord {
            let draft = MemoryDraft(kind: kind, topic: .architecture, title: "Synthetic knowledge", body: text,
                sources: [.init(scope: scope, origin: .humanStatement, label: "Synthetic fixture", capturedAt: Date())],
                environmentScope: environments, changeReason: "Reviewed source", knowledgePath: KnowledgePath(rawValue: path)!)
            let proposal = try await memory.prepare(draft, in: scope)
            return try await memory.publishReviewed(proposal, in: scope)
        }
        func search(_ index: KnowledgeSearchIndex, _ query: String = "refund", kinds: Set<KnowledgeRecordKind> = [.confirmed, .requirement],
                    paths: KnowledgePathFilter = try! .init(), limit: Int = 50) async throws -> KnowledgeSearchPage {
            try await index.search(query, in: scope, environment: environment, kinds: kinds, paths: paths, limit: limit)
        }
    }

    func testFTSFindsCurrentSourcesAndExcludesUncertainKindsByDefault() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let confirmed = try await f.record("Refund transfers require review")
        _ = try await f.record("Refund interpretation", path: "qa/note", kind: .note)
        _ = try await f.record("Refund unknown import", path: "qa/inbox", kind: .inbox)
        let id = RequirementID(rawValue: "refund-state")!
        let proposal = try await f.requirements.prepare(.init(description: "Refund state is checked", changeReason: "Synthetic", status: .active), id: id, expectedVersion: nil, in: f.scope)
        _ = try await f.requirements.publishReviewed(proposal, in: f.scope)
        let index = try f.index()
        do { _ = try await f.search(index); XCTFail() } catch { XCTAssertEqual(error as? KnowledgeIndexError, .notBuilt) }
        _ = try await index.rebuild(memory: f.memory, requirements: f.requirements, redactor: f.redactor())
        let page = try await f.search(index, "REFUND")
        XCTAssertEqual(Set(page.hits.map(\.kind)), [.confirmed, .requirement]); XCTAssertEqual(page.hits.count, 2)
        XCTAssertEqual(page.hits.first?.fingerprint, try confirmed.fingerprint)
        let notes = try await f.search(index, kinds: [.note, .inbox]); XCTAssertEqual(notes.hits.count, 2)
        let reopened = try f.index(); let restored = try await f.search(reopened)
        XCTAssertEqual(restored.hits, page.hits); XCTAssertEqual(restored.generation, 1)
    }

    func testPathFiltersAreCaseSensitiveAndRejectTraversalAndSiblingPrefixes() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.record("refund", path: "api/paynet/response")
        _ = try await f.record("refund", path: "api/paynet-private/response")
        _ = try await f.record("refund", path: "api/paynet/finance/private")
        _ = try await f.record("refund", path: "API/paynet/response")
        let index = try f.index(); _ = try await index.rebuild(memory: f.memory, requirements: f.requirements, redactor: f.redactor())
        let filter = try KnowledgePathFilter(include: ["api/paynet/**"], exclude: ["api/paynet/finance/**"])
        let hits = try await f.search(index, paths: filter)
        XCTAssertEqual(hits.hits.map(\.path.rawValue), ["api/paynet/response"])
        for path in ["../api", "/api", "api//x", "api/../x", "api\\x", "api/*/x"] {
            XCTAssertThrowsError(try KnowledgePathFilter(include: [path]))
        }
        let empty = try await f.search(index, paths: .init(include: [])); XCTAssertTrue(empty.hits.isEmpty)
        let excluded = try await f.search(index, paths: .init(exclude: ["**"])); XCTAssertTrue(excluded.hits.isEmpty)
    }

    func testProjectWorkspaceAndEnvironmentProjectionsRemainIsolated() async throws {
        let f = try await Fixture(), other = try await Fixture(); defer { f.remove(); other.remove() }
        let first = try await f.record("refund local")
        let foreign = try await other.record("refund foreign")
        let index = try f.index(); _ = try await index.rebuild([KnowledgeIndexDocument(memory: first)], redactor: f.redactor())
        let otherIndex = try KnowledgeSearchIndex(database: f.location, scope: other.scope, environment: other.environment)
        _ = try await otherIndex.rebuild([KnowledgeIndexDocument(memory: foreign)], redactor: other.redactor())
        let sibling = try await f.catalog.createProject(in: f.scope.workspaceID, name: "Synthetic sibling")
        let siblingStore = try await f.catalog.memoryStore(in: sibling.scope)
        let draft = MemoryDraft(kind: .confirmed, topic: .architecture, title: "Sibling", body: "refund sibling",
            sources: [.init(scope: sibling.scope, origin: .humanStatement, label: "Synthetic", capturedAt: Date())], changeReason: "Reviewed")
        let pending = try await siblingStore.prepare(draft, in: sibling.scope)
        let siblingRecord = try await siblingStore.publishReviewed(pending, in: sibling.scope)
        let siblingIndex = try KnowledgeSearchIndex(database: f.location, scope: sibling.scope, environment: f.environment)
        let siblingRedactor = try ContentRedactor(context: .init(scope: sibling.scope, environmentID: f.environment, runID: RunID()))
        _ = try await siblingIndex.rebuild([KnowledgeIndexDocument(memory: siblingRecord)], redactor: siblingRedactor)
        let otherEnvironment = EnvironmentID()
        let environmentIndex = try KnowledgeSearchIndex(database: f.location, scope: f.scope, environment: otherEnvironment)
        _ = try await environmentIndex.rebuild([], redactor: f.redactor(environment: otherEnvironment))
        let local = try await f.search(index); XCTAssertEqual(local.hits.map(\.sourceID), ["memory/\(first.id)"])
        let empty = try await environmentIndex.search("refund", in: f.scope, environment: otherEnvironment); XCTAssertTrue(empty.hits.isEmpty)
        do { _ = try await index.search("refund", in: other.scope, environment: f.environment); XCTFail() }
        catch { XCTAssertEqual(error as? OperationalStoreError, .scopeMismatch) }
        do { _ = try await index.rebuild([KnowledgeIndexDocument(memory: foreign)], redactor: f.redactor()); XCTFail() }
        catch { XCTAssertEqual(error as? OperationalStoreError, .scopeMismatch) }
        let stillLocal = try await f.search(index); XCTAssertEqual(stillLocal.hits, local.hits)
    }

    func testRebuildRemovesArchivedSourcesAndRejectsStaleGenerationAtomically() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let record = try await f.record("refund original")
        let index = try f.index(); _ = try await index.rebuild(memory: f.memory, requirements: f.requirements, redactor: f.redactor())
        do { _ = try await index.rebuild([], redactor: f.redactor(), expectedGeneration: 0); XCTFail() }
        catch { XCTAssertEqual(error as? KnowledgeIndexError, .staleGeneration) }
        let old = try await f.search(index); XCTAssertEqual(old.hits.count, 1); XCTAssertEqual(old.generation, 1)
        var draft = record.content; draft.disposition = .archived; draft.changeReason = "Reviewed archive"
        let proposal = try await f.memory.prepare(draft, id: record.id, expectedRevision: 1, in: f.scope)
        _ = try await f.memory.publishReviewed(proposal, in: f.scope)
        let next = try await index.rebuild(memory: f.memory, requirements: f.requirements, redactor: f.redactor(), expectedGeneration: 1)
        let cleared = try await f.search(index); XCTAssertEqual(next, 2); XCTAssertTrue(cleared.hits.isEmpty)
    }

    func testRedactionOccursBeforeIndexPersistenceAndLiteralQueriesCannotBroadenScope() async throws {
        let f = try await Fixture(); defer { f.remove() }
        _ = try await f.record("password: synthetic-private-value-9285")
        let index = try f.index(); _ = try await index.rebuild(memory: f.memory, requirements: f.requirements, redactor: f.redactor())
        let all = try await f.search(index, "")
        XCTAssertEqual(all.hits.count, 1); XCTAssertTrue(all.hits[0].bodyJSON.contains("REDACTED"))
        XCTAssertFalse(all.hits[0].bodyJSON.contains("synthetic-private-value-9285"))
        let hidden = try await f.search(index, "synthetic-private-value-9285"); XCTAssertTrue(hidden.hits.isEmpty)
        let literal = try await f.search(index, "refund OR nonexistent"); XCTAssertTrue(literal.hits.isEmpty)
        for suffix in ["", "-wal", "-shm"] {
            let path = URL(fileURLWithPath: f.location.path + suffix)
            if let bytes = try? Data(contentsOf: path) { XCTAssertNil(bytes.range(of: Data("synthetic-private-value-9285".utf8))) }
        }
    }

    func testPaginationInputLimitsAndCancelledRebuildPreservePreviousGeneration() async throws {
        let f = try await Fixture(); defer { f.remove() }
        let first = try await f.record("refund first", path: "qa/a"), second = try await f.record("refund second", path: "qa/b")
        let index = try f.index(); _ = try await index.rebuild(memory: f.memory, requirements: f.requirements, redactor: f.redactor())
        let page = try await f.search(index, limit: 1); XCTAssertEqual(page.hits.count, 1); XCTAssertTrue(page.hasMore)
        let cursor = try XCTUnwrap(page.nextCursor)
        let next = try await index.search("refund", in: f.scope, environment: f.environment, after: cursor, limit: 1)
        XCTAssertEqual(next.hits.count, 1); XCTAssertNil(next.nextCursor)
        XCTAssertNotEqual(page.hits.first?.sourceID, next.hits.first?.sourceID)
        do { _ = try await index.search("different", in: f.scope, environment: f.environment, after: cursor); XCTFail() }
        catch { XCTAssertEqual(error as? KnowledgeIndexError, .invalidInput) }
        do { _ = try await f.search(index, String(repeating: "word ", count: 17)); XCTFail() }
        catch { XCTAssertEqual(error as? KnowledgeIndexError, .invalidInput) }
        do { _ = try await index.rebuild([KnowledgeIndexDocument(memory: first), KnowledgeIndexDocument(memory: first)], redactor: f.redactor()); XCTFail() }
        catch { XCTAssertEqual(error as? KnowledgeIndexError, .limitExceeded) }
        let task = Task { try Task.checkCancellation(); return try await index.rebuild([], redactor: f.redactor()) }; task.cancel()
        do { _ = try await task.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let intact = try await f.search(index); XCTAssertEqual(Set(intact.hits.map(\.sourceID)), ["memory/\(first.id)", "memory/\(second.id)"])
        XCTAssertEqual(intact.generation, 1)
        _ = try await index.rebuild(memory: f.memory, requirements: f.requirements, redactor: f.redactor())
        do { _ = try await index.search("refund", in: f.scope, environment: f.environment, after: cursor); XCTFail() }
        catch { XCTAssertEqual(error as? KnowledgeIndexError, .staleGeneration) }
    }
}
