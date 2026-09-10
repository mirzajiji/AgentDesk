#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class NativeRunServiceTests: XCTestCase {
    func testLocalReviewDispatchAndScopedEvidenceFlow() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(disposition: .approval)
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root, configuration: f.configuration,
            captureRepository: false, provider: f.provider)
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect synthetic content")
        let before = try await service.run(prepared.runID); XCTAssertEqual(before?.state, .waitingForApproval)
        do { _ = try await service.start(prepared); XCTFail("Native service skipped review") } catch {}
        let approval = try XCTUnwrap(prepared.approval)
        let reviewed = try await service.review(prepared, approve: true, expectedSequence: approval.sequence)
        XCTAssertEqual(reviewed.state, .approved)
        let execution = try await service.start(prepared), outcome = await execution.result()
        XCTAssertEqual(outcome.state, .completed)
        let records = try await service.evidenceRecords(for: prepared.runID), history = try await service.history(for: prepared.runID)
        XCTAssertFalse(records.isEmpty); XCTAssertEqual(history.last?.state, .completed)
        let output = try await service.artifact(XCTUnwrap(outcome.finalArtifactID), for: prepared.runID)
        XCTAssertFalse(output?.text.contains("fixture-provider-secret") == true)
        do { _ = try await service.evidenceRecords(for: RunID()); XCTFail("Unbound run read") } catch {}
        // Same project but a different environment/agent cannot disclose this run through a fresh service.
        let other = try await RunCoordinatorTests.Fixture.make()
        await other.coordinator.shutdown()
        let foreign = try await NativeRunService.open(database: f.database, directory: f.root, configuration: other.configuration,
            captureRepository: false, provider: other.provider)
        do { _ = try await foreign.artifact(XCTUnwrap(outcome.finalArtifactID), for: prepared.runID); XCTFail("Foreign artifact disclosed") } catch {}
        await foreign.shutdown(); await other.remove()
        await service.shutdown(); await f.remove()
    }
    func testInstalledPolicyStopsActiveNativeRunAndReadDenialIsEnforced() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(mode: .quiet)
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root, configuration: f.configuration,
            captureRepository: false, provider: f.provider)
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect")
        let execution = try await service.start(prepared)
        await f.provider.waitForStart()
        let prior = f.configuration.policy
        let denied = try PolicyDocument(level: .environment, workspaceID: f.scope.workspaceID, projectID: f.scope.projectID,
            environmentID: f.configuration.environment.id, rules: [])
        try await service.installPolicy(PolicySnapshot(workspace: prior.workspace, project: prior.project,
            environment: denied, environmentKind: prior.environmentKind))
        let outcome = await execution.result(); XCTAssertEqual(outcome.state, .failed); XCTAssertEqual(outcome.failure, .unauthorized)
        do { _ = try await service.progress(for: prepared.runID); XCTFail("Denied progress read") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        await service.shutdown(); await f.remove()
    }
    func testClosedServiceRejectsPreparationAndInvalidRepositoryStopsBeforeExecution() async throws {
        let f = try await RunCoordinatorTests.Fixture.make()
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root, configuration: f.configuration,
            captureRepository: true, provider: f.provider)
        do {
            _ = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect")
            XCTFail("Invalid repository accepted")
        } catch {}
        let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty)
        await service.shutdown()
        do { _ = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect"); XCTFail("Closed service") }
        catch { XCTAssertEqual(error as? RunCoordinatorError, .closed) }
        await f.remove()
    }
}
#endif
