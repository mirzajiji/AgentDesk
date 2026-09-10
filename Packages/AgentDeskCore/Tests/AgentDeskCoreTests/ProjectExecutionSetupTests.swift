import Darwin
import Foundation
import XCTest
@testable import AgentDeskCore

@MainActor
final class ProjectExecutionSetupTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let catalog: WorkspaceCatalog
        let scope: ProjectScope
        let agent: AgentSnapshot
        let service: ProjectExecutionSetupService
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let catalog = try WorkspaceCatalog(container: root), workspace = try await catalog.createWorkspace(name: "Synthetic")
            let project = try await catalog.createProject(in: workspace.id, name: "Synthetic Project")
            let agent = try await catalog.agentStore(in: project.scope).create(AgentTemplate.general.draft, in: project.scope)
            return Self(root: root, catalog: catalog, scope: project.scope, agent: agent,
                service: ProjectExecutionSetupService(catalog: catalog, scope: project.scope))
        }
        func configure() async throws {
            for level in [ExecutionConfigurationLevel.workspace, .project] {
                let proposal = try await service.proposedDefaults(at: level)
                _ = try await service.save(proposal, at: level, expectedRevision: nil)
            }
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    func testPersistentCatalogLockFailsClosedAndRetrySleepIsCancellable() async throws {
        let f = try await Fixture.make(); defer { f.remove() }; try await f.configure()
        let context = try await f.service.preview(agentID: f.agent.id)
        let descriptor = Darwin.open(f.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { flock(descriptor, LOCK_UN); Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let start = ContinuousClock.now
        do { try await f.service.validate(context); XCTFail("Unverified context accepted") }
        catch { XCTAssertEqual(error as? CatalogError, .busy) }
        XCTAssertLessThan(start.duration(to: .now), .seconds(2))
        let validation = Task { try await f.service.validate(context) }
        try await Task.sleep(for: .milliseconds(10))
        validation.cancel()
        do { try await validation.value; XCTFail("Cancelled validation completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testTransientCatalogLockDoesNotInvalidateUnchangedReviewedContext() async throws {
        let f = try await Fixture.make(); defer { f.remove() }; try await f.configure()
        let context = try await f.service.preview(agentID: f.agent.id)
        let descriptor = Darwin.open(f.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { Darwin.close(descriptor) }
        XCTAssertEqual(flock(descriptor, LOCK_EX | LOCK_NB), 0)
        let validation = Task { try await f.service.validate(context) }
        try await Task.sleep(for: .milliseconds(40))
        XCTAssertEqual(flock(descriptor, LOCK_UN), 0)
        try await validation.value
    }

    func testReadingAndProposingDefaultsDoNotWriteAndExplicitSaveRequiresReview() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let before = try FileManager.default.subpathsOfDirectory(atPath: f.root.path).sorted()
        let missing = try await f.service.settings(); XCTAssertNil(missing.workspace); XCTAssertNil(missing.project)
        let workspace = try await f.service.proposedDefaults(at: .workspace), project = try await f.service.proposedDefaults(at: .project)
        XCTAssertEqual(try FileManager.default.subpathsOfDirectory(atPath: f.root.path).sorted(), before)
        do { _ = try await f.service.preview(agentID: f.agent.id); XCTFail("Invented an environment") }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .unavailableEnvironment) }
        _ = try await f.service.save(workspace, at: .workspace, expectedRevision: nil)
        _ = try await f.service.save(project, at: .project, expectedRevision: nil)
        let preview = try await f.service.preview(agentID: f.agent.id)
        XCTAssertEqual(preview.configuration.environment.name, "Development")
        XCTAssertEqual(preview.configuration.environment.kind, .development)
        XCTAssertEqual(preview.configuration.requestedAccess, .readOnly)
        XCTAssertNil(preview.configuration.modelIdentifier)
        XCTAssertEqual(preview.configuration.timeoutSeconds, 600)
        XCTAssertEqual(preview.configuration.maximumSteps, 30)
        XCTAssertEqual(preview.configuration.maximumOutputBytes, 65_536)
        for document in [preview.configuration.policy.workspace, preview.configuration.policy.project, preview.configuration.policy.environment] {
            for operation in PolicyOperation.allCases {
                let expected: PolicyDisposition = operation == .readEvidence ? .allow : (operation == .runReadOnlyAgent ? .approval : .deny)
                XCTAssertEqual(document.disposition(for: operation), expected)
            }
        }
        try await f.service.validate(preview)
        let reopened = ProjectExecutionSetupService(catalog: f.catalog, scope: f.scope)
        let repeated = try await reopened.preview(agentID: f.agent.id); XCTAssertEqual(repeated, preview)
    }
    func testExistingDocumentsAndAdvancedRestrictionsArePreservedWithRevisionConflicts() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let original = ExecutionConfigurationDraft(settings: .init(modelIdentifier: "configured-model", timeoutSeconds: 45,
            allowedModelIdentifiers: ["configured-model"], allowedEnvironmentIDs: [], outputSchema: .object(["ok": .boolean])), workspaceLocked: true)
        let first = try await f.service.save(original, at: .workspace, expectedRevision: nil)
        do { _ = try await f.service.proposedDefaults(at: .workspace); XCTFail("Replaced existing configuration") }
        catch { XCTAssertEqual(error as? ExecutionSetupError, .alreadyConfigured) }
        let project = try await f.service.proposedDefaults(at: .project)
        _ = try await f.service.save(project, at: .project, expectedRevision: nil)
        let state = try await f.service.settings(); XCTAssertEqual(state.workspace, first)
        XCTAssertNil(state.workspace?.draft.policy) // Missing policy remains deny-all, not silently filled.
        do { _ = try await f.service.save(.init(), at: .workspace, expectedRevision: nil); XCTFail("Lost an existing edit") }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .staleRevision) }
        var edited = original; edited.settings.timeoutSeconds = 40
        let second = try await f.service.save(edited, at: .workspace, expectedRevision: first.revision)
        XCTAssertEqual(second.draft.settings.outputSchema, original.settings.outputSchema)
        let history = try await f.catalog.executionConfigurationStore(in: f.scope).configuration(at: .workspace, in: f.scope, revision: first.revision)
        XCTAssertEqual(history, first)
    }
    func testContextRefreshUsesLatestInstructionsAndAgentWithoutRewritingPriorPreview() async throws {
        let f = try await Fixture.make(); defer { f.remove() }; try await f.configure()
        let original = try await f.service.preview(agentID: f.agent.id)
        let instructions = try await f.catalog.instructionStore(in: f.scope)
        let document = InstructionDocument(title: "Synthetic project context", text: "Review the current synthetic behavior.")
        _ = try await instructions.save(.init(documents: [document], roots: [document.id]), at: .project, in: f.scope, expectedRevision: nil)
        do { try await f.service.validate(original); XCTFail("Stale instruction preview") }
        catch { XCTAssertEqual(error as? ExecutionSetupError, .staleContext) }
        let updated = try await f.service.preview(agentID: f.agent.id)
        XCTAssertTrue(updated.instructions.text.contains(document.text)); XCTAssertFalse(original.instructions.text.contains(document.text))
        let agents = try await f.catalog.agentStore(in: f.scope)
        var draft = f.agent.draft; draft.instructions = "Use revised synthetic instructions."
        let agent = try await agents.update(f.agent.id, in: f.scope, expectedRevision: 1, draft: draft)
        do { try await f.service.validate(updated); XCTFail("Stale agent preview") }
        catch { XCTAssertEqual(error as? ExecutionSetupError, .staleContext) }
        let current = try await f.service.preview(agentID: f.agent.id)
        XCTAssertEqual(current.agent, agent); XCTAssertEqual(current.configuration.agentRevision, 2)
        XCTAssertEqual(current.instructions.agentRevision, 2)
        _ = try await agents.setArchived(true, for: f.agent.id, in: f.scope, expectedRevision: 2)
        do { try await f.service.validate(current); XCTFail("Archived agent") }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .disabledAgent) }
    }
    func testDefaultEnvironmentChangeAndPolicyRevisionInvalidatePreparedContext() async throws {
        let f = try await Fixture.make(); defer { f.remove() }; try await f.configure()
        let original = try await f.service.preview(agentID: f.agent.id, run: .init(timeoutSeconds: 15))
        XCTAssertEqual(original.configuration.timeoutSeconds, 15)
        let state = try await f.service.settings(), saved = try XCTUnwrap(state.project)
        var draft = saved.draft
        let other = ProjectEnvironment(scope: f.scope, name: "Synthetic test", kind: .test)
        draft.environments.append(other); draft.defaultEnvironmentID = other.id
        let revised = try await f.service.save(draft, at: .project, expectedRevision: saved.revision)
        do { try await f.service.validate(original); XCTFail("Default environment silently frozen as explicit selection") }
        catch { XCTAssertEqual(error as? ExecutionSetupError, .staleContext) }
        let current = try await f.service.preview(agentID: f.agent.id)
        XCTAssertEqual(current.configuration.environment.id, other.id)
        XCTAssertEqual(current.configuration.policy.environment.disposition(for: .runReadOnlyAgent), .deny)
        let explicit = try await f.service.preview(agentID: f.agent.id, environmentID: original.configuration.environment.id)
        XCTAssertEqual(explicit.configuration.environment.id, original.configuration.environment.id)
        var locked = try XCTUnwrap(state.workspace).draft; locked.workspaceLocked = true
        _ = try await f.service.save(locked, at: .workspace, expectedRevision: state.workspace?.revision)
        do { try await f.service.validate(explicit); XCTFail("Workspace policy edit ignored") }
        catch { XCTAssertEqual(error as? ExecutionSetupError, .staleContext) }
        var disabled = revised.draft; disabled.environments[0].enabled = false
        _ = try await f.service.save(disabled, at: .project, expectedRevision: revised.revision)
        do { _ = try await f.service.preview(agentID: f.agent.id, environmentID: original.configuration.environment.id); XCTFail("Disabled environment") }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .unavailableEnvironment) }
    }
    func testForeignScopesCancellationAndMalformedSettingsCannotBecomeDefaults() async throws {
        let f = try await Fixture.make(); defer { f.remove() }; try await f.configure()
        let current = try await f.service.preview(agentID: f.agent.id)
        let sibling = try await f.catalog.createProject(in: f.scope.workspaceID, name: "Sibling")
        let other = ProjectExecutionSetupService(catalog: f.catalog, scope: sibling.scope)
        do { try await other.validate(current); XCTFail("Foreign context") }
        catch { XCTAssertEqual(error as? ExecutionSetupError, .scopeMismatch) }
        do { _ = try await other.preview(agentID: f.agent.id); XCTFail("Foreign agent") } catch {}
        let foreign = ProjectExecutionSetupService(catalog: f.catalog, scope: .init(workspaceID: WorkspaceID(), projectID: f.scope.projectID))
        do { _ = try await foreign.proposedDefaults(at: .project); XCTFail("Unknown workspace") } catch {}
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.service.preview(agentID: f.agent.id)
        }
        do { _ = try await cancelled.value; XCTFail("Cancellation ignored") } catch { XCTAssertTrue(error is CancellationError) }
        let file = f.root.appendingPathComponent("\(f.scope.workspaceID)/Projects/\(f.scope.projectID)/Execution/current.json")
        let invalid = Data("{invalid".utf8); try invalid.write(to: file)
        do { _ = try await f.service.proposedDefaults(at: .project); XCTFail("Corruption replaced by defaults") }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .invalidConfiguration) }
        XCTAssertEqual(try Data(contentsOf: file), invalid)
    }
    func testConcurrentInitialSavesHaveOneWinnerAndSharedWorkspaceSettingsStayScoped() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let second = ProjectExecutionSetupService(catalog: f.catalog, scope: f.scope)
        let firstProposal = try await f.service.proposedDefaults(at: .workspace)
        var secondProposal = firstProposal; secondProposal.settings.timeoutSeconds = 90
        let operations = [(f.service, firstProposal), (second, secondProposal)].map { service, proposal in
            Task { try await service.save(proposal, at: .workspace, expectedRevision: nil) }
        }
        var winner: ExecutionConfigurationSnapshot?
        for task in operations {
            do { let saved = try await task.value; XCTAssertNil(winner); winner = saved }
            catch { XCTAssertTrue(error as? ExecutionConfigurationError == .staleRevision || error as? CatalogError == .busy) }
        }
        XCTAssertNotNil(winner)
        let sibling = try await f.catalog.createProject(in: f.scope.workspaceID, name: "Sibling")
        let shared = try await ProjectExecutionSetupService(catalog: f.catalog, scope: sibling.scope).settings()
        XCTAssertEqual(shared.workspace, winner); XCTAssertNil(shared.project)
        let workspace = try await f.catalog.createWorkspace(name: "Another workspace")
        let project = try await f.catalog.createProject(in: workspace.id, name: "Another project")
        let isolated = try await ProjectExecutionSetupService(catalog: f.catalog, scope: project.scope).settings()
        XCTAssertNil(isolated.workspace); XCTAssertNil(isolated.project)
    }
}
