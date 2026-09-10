#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class BugEvidenceTests: XCTestCase {
    func testVerifiedProviderOutputRemainsInterpretationAndRejectsWrongFingerprints() async throws {
        let f = try await RunCoordinatorTests.Fixture.make()
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect synthetic behavior")
        let execution = try await service.start(prepared), outcome = await execution.result()
        XCTAssertEqual(outcome.state, .completed)
        let records = try await service.evidenceRecords(for: prepared.runID)
        let record = try XCTUnwrap(records.first { $0.id == outcome.finalArtifactID })
        func reference(_ fingerprint: ActionFingerprint) -> BugEvidenceReference {
            .init(scope: f.scope, environment: f.configuration.environment.id, run: prepared.runID,
                  agent: f.configuration.agentID, artifact: record.id, sanitizedFingerprint: fingerprint)
        }
        let verified = try await service.verifyBugEvidence(reference(record.fingerprint))
        XCTAssertEqual(verified.record.basis, .interpretation)
        XCTAssertEqual(verified.record.source, .providerResponse)
        XCTAssertEqual(verified.reference.artifact, record.id)
        do { _ = try await service.verifyBugEvidence(reference(.canonical("wrong"))); XCTFail("Forged fingerprint accepted") }
        catch { XCTAssertEqual(error as? BugRegistryError, .unavailableReference) }
        let trace = try XCTUnwrap(records.first { $0.kind == .trace })
        let traceReference = BugEvidenceReference(scope: f.scope, environment: f.configuration.environment.id, run: prepared.runID,
            agent: f.configuration.agentID, artifact: trace.id, sanitizedFingerprint: trace.fingerprint)
        let checkedTrace = try await service.verifyBugEvidence(traceReference)
        XCTAssertEqual(checkedTrace.record.kind, .trace)
        await service.shutdown(); await f.remove()
    }

    func testReferencesCannotGrantAccessAcrossScopesAgentsEnvironmentsOrRevokedPolicy() async throws {
        let f = try await RunCoordinatorTests.Fixture.make()
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect")
        let records = try await service.evidenceRecords(for: prepared.runID), record = try XCTUnwrap(records.first)
        let correct = BugEvidenceReference(scope: f.scope, environment: f.configuration.environment.id, run: prepared.runID,
            agent: f.configuration.agentID, artifact: record.id, sanitizedFingerprint: record.fingerprint)
        for wrong in [
            BugEvidenceReference(scope: .init(workspaceID: f.scope.workspaceID, projectID: ProjectID()), environment: correct.environment,
                run: correct.run, agent: correct.agent, artifact: correct.artifact, sanitizedFingerprint: correct.sanitizedFingerprint),
            BugEvidenceReference(scope: f.scope, environment: EnvironmentID(), run: correct.run, agent: correct.agent,
                artifact: correct.artifact, sanitizedFingerprint: correct.sanitizedFingerprint),
            BugEvidenceReference(scope: f.scope, environment: correct.environment, run: correct.run, agent: AgentID(),
                artifact: correct.artifact, sanitizedFingerprint: correct.sanitizedFingerprint)
        ] {
            do { _ = try await service.verifyBugEvidence(wrong); XCTFail("Foreign reference authorized") }
            catch { XCTAssertEqual(error as? BugRegistryError, .scopeMismatch) }
        }
        let prior = f.configuration.policy
        let denied = try PolicyDocument(level: .environment, workspaceID: f.scope.workspaceID,
            projectID: f.scope.projectID, environmentID: correct.environment, rules: [])
        try await service.installPolicy(PolicySnapshot(workspace: prior.workspace, project: prior.project,
            environment: denied, environmentKind: prior.environmentKind))
        do { _ = try await service.verifyBugEvidence(correct); XCTFail("Revoked evidence released") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        await service.shutdown(); await f.remove()
    }
}
#endif
