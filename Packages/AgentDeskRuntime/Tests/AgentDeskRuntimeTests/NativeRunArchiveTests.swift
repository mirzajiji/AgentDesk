#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class NativeRunArchiveTests: XCTestCase {
    func testArchiveReadsActiveRunWithoutRecoveryOrProviderAndRechecksPolicy() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(mode: .quiet)
        let prepared = try await f.prepare(), execution = try await f.coordinator.start(prepared.token)
        await f.provider.waitForStart()
        let catalog = try WorkspaceCatalog(container: f.root), setup = ProjectExecutionSetupService(catalog: catalog, scope: f.scope)
        let archive = try NativeRunArchive(database: f.database, scope: f.scope, agentID: f.configuration.agentID,
            environmentID: f.configuration.environment.id, current: {
                try await setup.preview(agentID: f.configuration.agentID, environmentID: f.configuration.environment.id).configuration
            })
        let runs = try await archive.runs()
        XCTAssertEqual(runs.map(\.id), [prepared.runID]); XCTAssertFalse(runs[0].state.isTerminal)
        let records = try await archive.evidenceRecords(for: prepared.runID)
        let command = try XCTUnwrap(records.first { $0.kind == .command })
        let input = try await archive.artifact(command.id, for: prepared.runID)
        XCTAssertFalse(input?.text.contains("fixture-input-secret") == true)
        XCTAssertEqual(f.provider.cancellations.withLock { $0 }, 0)
        let requests = await f.provider.requests; XCTAssertEqual(requests.count, 1)
        let settings = try await setup.settings(), project = try XCTUnwrap(settings.project)
        var denied = project.draft
        denied.policy = try PolicyDocument(level: .project, workspaceID: f.scope.workspaceID, projectID: f.scope.projectID,
            rules: [PolicyRule(.readEvidence, .deny), PolicyRule(.runReadOnlyAgent, .allow)])
        _ = try await setup.save(denied, at: .project, expectedRevision: project.revision)
        do { _ = try await archive.runs(); XCTFail("Archive reused stale policy") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        do { _ = try await archive.artifact(command.id, for: prepared.runID); XCTFail("Revoked evidence disclosed") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        execution.cancel(); _ = await execution.result(); await f.remove()
    }

    func testEmptyArchiveCreatesNoDatabaseAndForeignContextIsRejected() async throws {
        let f = try await RunCoordinatorTests.Fixture.make()
        let absent = f.root.appendingPathComponent("never-created.sqlite")
        let archive = try NativeRunArchive(database: absent, scope: f.scope, agentID: f.configuration.agentID,
            environmentID: f.configuration.environment.id, current: { f.configuration })
        let runs = try await archive.runs(); XCTAssertTrue(runs.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        do { _ = try await archive.evidenceRecords(for: RunID()); XCTFail("Unregistered run read") }
        catch { XCTAssertEqual(error as? EvidenceStoreError, .unregisteredRun) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        let foreign = try NativeRunArchive(database: f.database, scope: f.scope, agentID: AgentID(),
            environmentID: f.configuration.environment.id, current: { f.configuration })
        do { _ = try await foreign.runs(); XCTFail("Foreign configuration accepted") }
        catch { XCTAssertEqual(error as? AuthorizationError, .scopeMismatch) }
        await f.remove()
    }
}
#endif
