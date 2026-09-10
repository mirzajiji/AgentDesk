#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import Foundation
import XCTest
@testable import AgentDesk
@testable import AgentDeskRuntime

@MainActor
final class RunEvidenceModelTests: XCTestCase {
    func testClosingBrowserDuringReadCannotReopenOrSelectLateResult() async throws {
        let reader = PausedEvidenceReader(), model = RunEvidenceModel()
        let result = RunOutcome(runID: RunID(), state: .completed, failure: nil, finalArtifactID: UUID())
        let loading = Task { await model.showResult(result, using: reader) }
        await reader.waitUntilReading()
        model.clear()
        await reader.release()
        await loading.value
        XCTAssertFalse(model.isOpen); XCTAssertTrue(model.runs.isEmpty)
        XCTAssertNil(model.selectedRun); XCTAssertNil(model.content); XCTAssertNil(model.errorMessage)
        let reads = await reader.evidenceReads
        XCTAssertEqual(reads, 0, "A stale automatic result must not begin another evidence read")
    }
    func testResultInspectionUsesStoredRedactedEvidenceAndClearsOnForeignSelection() async throws {
        let f = try await RunCoordinatorTests.Fixture.make()
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect")
        let execution = try await service.start(prepared), result = await execution.result()
        let model = RunEvidenceModel()
        await model.showResult(result, using: service)
        XCTAssertEqual(model.runs.map(\.id), [prepared.runID]); XCTAssertFalse(model.moreRuns)
        XCTAssertEqual(model.selectedRun, prepared.runID)
        XCTAssertEqual(model.selectedRecord?.id, result.finalArtifactID)
        let record = try XCTUnwrap(model.records.first { $0.id == result.finalArtifactID })
        let text = try XCTUnwrap(model.content?.text)
        XCTAssertTrue(text.contains("Observed synthetic file"))
        XCTAssertFalse(text.contains("fixture-provider-secret"))
        XCTAssertEqual(model.selectedRecord?.basis, .interpretation)
        await model.select(RunID())
        XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.content); XCTAssertNotNil(model.errorMessage)
        await model.inspect(record)
        XCTAssertNil(model.content, "A stale record must not restore content from the prior selection")
        model.clear(); XCTAssertNil(model.errorMessage); XCTAssertTrue(model.runs.isEmpty)
        await service.shutdown(); await f.remove()
    }

    func testSwitchingServicesClearsPriorWorkspaceEvidenceAndClosedReadsFail() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(), other = try await RunCoordinatorTests.Fixture.make()
        await f.coordinator.shutdown(); await other.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let second = try await NativeRunService.open(database: other.database, directory: other.root,
            configuration: other.configuration, captureRepository: false, provider: other.provider)
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect")
        let model = RunEvidenceModel(); await model.load(service); await model.select(prepared.runID)
        XCTAssertFalse(model.records.isEmpty)
        await model.load(second)
        XCTAssertTrue(model.runs.isEmpty); XCTAssertTrue(model.records.isEmpty); XCTAssertNil(model.selectedRun)
        await second.shutdown(); await model.load(second)
        XCTAssertNotNil(model.errorMessage); XCTAssertNil(model.content)
        await service.shutdown(); await f.remove(); await other.remove()
    }
}

private actor PausedEvidenceReader: RunEvidenceReading {
    private var pending: CheckedContinuation<Void, Never>?
    private var started = false
    private var waiter: CheckedContinuation<Void, Never>?
    private(set) var evidenceReads = 0
    func waitUntilReading() async {
        if !started { await withCheckedContinuation { waiter = $0 } }
    }
    func release() { pending?.resume(); pending = nil }
    func runs(before: RunID?, limit: Int) async throws -> [StoredRun] {
        await withCheckedContinuation {
            pending = $0; started = true; waiter?.resume(); waiter = nil
        }
        return []
    }
    func evidenceRecords(for: RunID, after: Int64, limit: Int) async throws -> [EvidenceRecord] {
        evidenceReads += 1; return []
    }
    func artifact(_ id: UUID, for run: RunID) async throws -> StoredEvidenceContent? { nil }
    func trace(_ id: UUID, for run: RunID) async throws -> StoredTrace? { nil }
}
#endif
