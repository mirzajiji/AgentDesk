#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskRuntime
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDesk

@MainActor
final class NativeLiveOutputModelTests: XCTestCase {
    func testIncrementalOutputIsRedactedWithoutWaitingForRunCompletion() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let model = NativeLiveOutputModel(), token = model.bind(f.reader, context: f.context, agentID: f.agent)
        _ = try await f.store.appendTrace(f.text("Runtime evidence"), source: .runtime, basis: .observed)
        _ = try await f.store.appendTrace(f.text("First response password=synthetic-live-secret"), source: .providerResponse, basis: .interpretation)
        let first = await model.refresh(token); XCTAssertTrue(first)
        XCTAssertEqual(model.entries.count, 1)
        XCTAssertTrue(model.entries[0].text.contains("[REDACTED]"))
        XCTAssertFalse(model.entries[0].text.contains("synthetic-live-secret"))
        _ = try await f.store.publishArtifact(f.text("Second response"), kind: .output, source: .providerResponse, basis: .interpretation)
        let second = await model.refresh(token); XCTAssertTrue(second)
        XCTAssertEqual(model.entries.map(\.text).last, "Second response")
        let third = await model.refresh(token); XCTAssertTrue(third); XCTAssertEqual(model.entries.count, 2)
        let run = try await f.operations.run(f.context.runID, in: f.context.scope)
        XCTAssertFalse(try XCTUnwrap(run).state.isTerminal, "Output must be available before completion")
    }

    func testPreviewIsBoundedAndSignalsAbbreviation() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        for _ in 0..<110 {
            _ = try await f.store.appendTrace(f.text(String(repeating: "x", count: 3_000)), source: .providerResponse, basis: .interpretation)
        }
        let model = NativeLiveOutputModel(), token = model.bind(f.reader, context: f.context, agentID: f.agent)
        for _ in 0..<3 { let ok = await model.refresh(token); XCTAssertTrue(ok) }
        XCTAssertFalse(model.hasMore); XCTAssertTrue(model.abbreviated)
        XCTAssertLessThanOrEqual(model.entries.count, 100)
        XCTAssertLessThanOrEqual(model.entries.reduce(0) { $0 + $1.text.utf8.count }, 262_144)
        XCTAssertEqual(model.entries.last?.record.sequence, 110)
        _ = try await f.store.appendTrace(f.text(String(repeating: "z", count: 20_000)), source: .providerResponse, basis: .interpretation)
        let ok = await model.refresh(token); XCTAssertTrue(ok)
        XCTAssertEqual(model.entries.last?.text.count, 16_384)
    }

    func testForeignScopeRunEnvironmentAndAgentFailClosed() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        _ = try await f.store.appendTrace(f.text("Scoped response"), source: .providerResponse, basis: .interpretation)
        let contexts = [
            RedactionContext(scope: ProjectScope(workspaceID: WorkspaceID(), projectID: f.context.scope.projectID), environmentID: f.context.environmentID, runID: f.context.runID),
            RedactionContext(scope: ProjectScope(workspaceID: f.context.scope.workspaceID, projectID: ProjectID()), environmentID: f.context.environmentID, runID: f.context.runID),
            RedactionContext(scope: f.context.scope, environmentID: EnvironmentID(), runID: f.context.runID),
            RedactionContext(scope: f.context.scope, environmentID: f.context.environmentID, runID: RunID())
        ]
        for context in contexts {
            let model = NativeLiveOutputModel(), token = model.bind(f.reader, context: context, agentID: f.agent)
            let ok = await model.refresh(token); XCTAssertFalse(ok); XCTAssertTrue(model.entries.isEmpty)
            XCTAssertNotNil(model.errorMessage)
        }
        let model = NativeLiveOutputModel(), token = model.bind(f.reader, context: f.context, agentID: AgentID())
        let ok = await model.refresh(token); XCTAssertFalse(ok); XCTAssertTrue(model.entries.isEmpty)
    }

    func testLateReadAfterClearCannotRestoreOutput() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        _ = try await f.store.appendTrace(f.text("Late response"), source: .providerResponse, basis: .interpretation)
        await f.reader.pauseNextRead()
        let model = NativeLiveOutputModel(), token = model.bind(f.reader, context: f.context, agentID: f.agent)
        let reading = Task { await model.refresh(token) }
        await f.reader.waitUntilPaused(); model.clear()
        await f.reader.release(); let ok = await reading.value
        XCTAssertFalse(ok); XCTAssertTrue(model.entries.isEmpty); XCTAssertNil(model.errorMessage)
    }

    func testCancelledReadDoesNotPublishAndMissingContentClearsPriorOutput() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        _ = try await f.store.appendTrace(f.text("Response"), source: .providerResponse, basis: .interpretation)
        let model = NativeLiveOutputModel(), token = model.bind(f.reader, context: f.context, agentID: f.agent)
        await f.reader.pauseNextRead()
        let reading = Task { await model.refresh(token) }
        await f.reader.waitUntilPaused(); reading.cancel(); await f.reader.release()
        let cancelled = await reading.value; XCTAssertFalse(cancelled); XCTAssertTrue(model.entries.isEmpty)
        let ok = await model.refresh(token); XCTAssertTrue(ok); XCTAssertEqual(model.entries.count, 1)
        _ = try await f.store.appendTrace(f.text("Missing response"), source: .providerResponse, basis: .interpretation)
        await f.reader.hideContent()
        let failed = await model.refresh(token); XCTAssertFalse(failed); XCTAssertTrue(model.entries.isEmpty)
        XCTAssertNotNil(model.errorMessage)
    }

    private struct Fixture {
        let root: URL, context: RedactionContext, agent: AgentID
        let store: EvidenceStore, operations: OperationalStore, reader: LiveEvidenceReader
        static func make() async throws -> Fixture {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let context = RedactionContext(scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), runID: RunID())
            let agent = AgentID(), database = root.appendingPathComponent("operations.sqlite")
            let operations = try OperationalStore(database: database, workspaceID: context.scope.workspaceID)
            _ = try await operations.createRun(in: context.scope, id: context.runID, at: Date())
            let store = try EvidenceStore(database: database, context: context, agentID: agent)
            let snapshot = try ContentRedactor(context: context).redactText("Synthetic snapshot", in: context)
            _ = try await store.register(snapshot: snapshot, agentRevision: 1, configurationFingerprint: ActionFingerprint(bytes: Data("fixture".utf8)))
            return Fixture(root: root, context: context, agent: agent, store: store, operations: operations, reader: LiveEvidenceReader(store: store))
        }
        func text(_ text: String) throws -> RedactedText { try ContentRedactor(context: context).redactText(text, in: context) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor LiveEvidenceReader: RunEvidenceReading {
    let store: EvidenceStore
    private var pause = false, hidden = false
    private var pending: CheckedContinuation<Void, Never>?
    private var waiter: CheckedContinuation<Void, Never>?
    init(store: EvidenceStore) { self.store = store }
    func pauseNextRead() { pause = true }
    func hideContent() { hidden = true }
    func waitUntilPaused() async { if pending == nil { await withCheckedContinuation { waiter = $0 } } }
    func release() { pending?.resume(); pending = nil }
    func runs(before: RunID?, limit: Int) async throws -> [StoredRun] { [] }
    func evidenceRecords(for: RunID, after: Int64, limit: Int) async throws -> [EvidenceRecord] {
        if pause {
            pause = false
            await withCheckedContinuation { pending = $0; waiter?.resume(); waiter = nil }
        }
        return try await store.records(after: after, limit: limit)
    }
    func artifact(_ id: UUID, for run: RunID) async throws -> StoredEvidenceContent? { try await store.artifact(id) }
    func trace(_ id: UUID, for run: RunID) async throws -> StoredTrace? { hidden ? nil : try await store.trace(id) }
}
#endif
