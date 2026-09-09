import Foundation
import XCTest
@testable import AgentDeskCore

@MainActor
final class ExecutionConfigurationTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let catalog: WorkspaceCatalog
        let project: ProjectRecord
        let store: ProjectExecutionConfigurationStore
        let agents: ProjectAgentStore
        let agent: AgentSnapshot
        let environment: ProjectEnvironment
        var projectRoot: URL { root.appendingPathComponent("\(project.workspaceID)/Projects/\(project.id)") }
        init(profile: CodexAgentProfile = .init()) async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic Workspace")
            project = try await catalog.createProject(in: workspace.id, name: "Synthetic Project")
            store = try await catalog.executionConfigurationStore(in: project.scope)
            agents = try await catalog.agentStore(in: project.scope)
            agent = try await agents.create(AgentDraft(name: "Reader", instructions: "Report synthetic evidence.", profile: profile), in: project.scope)
            environment = ProjectEnvironment(scope: project.scope, name: "Synthetic test", kind: .test)
        }
        func save(_ settings: ExecutionSettings = .init()) async throws -> ExecutionConfigurationSnapshot {
            try await store.save(ExecutionConfigurationDraft(settings: settings, environments: [environment], defaultEnvironmentID: environment.id),
                                 at: .project, in: project.scope, expectedRevision: nil)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    func testFreshProjectRequiresExplicitEnvironmentAndVersionedReopenKeepsHistory() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        do { _ = try await f.store.preview(for: f.agent, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .unavailableEnvironment) }
        let first = try await f.save()
        let bytes = try Data(contentsOf: f.projectRoot.appendingPathComponent("Execution/Versions/1/execution.json"))
        var updated = first.draft; updated.settings.timeoutSeconds = 100
        _ = try await f.store.save(updated, at: .project, in: f.project.scope, expectedRevision: 1)
        let reopened = try await f.catalog.executionConfigurationStore(in: f.project.scope)
        let historic = try await reopened.configuration(at: .project, in: f.project.scope, revision: 1)
        XCTAssertEqual(historic, first)
        XCTAssertEqual(try Data(contentsOf: f.projectRoot.appendingPathComponent("Execution/Versions/1/execution.json")), bytes)
        let effective = try await reopened.preview(for: f.agent, in: f.project.scope)
        XCTAssertEqual(effective.timeoutSeconds, 100); XCTAssertEqual(effective.environment, f.environment)
        XCTAssertEqual(effective.agentRevision, 1)
        XCTAssertEqual(effective.sources.map(\.layer), [.global, .project, .environment, .agent])
        XCTAssertEqual(effective.origins["timeoutSeconds"], .project)
        do { _ = try await reopened.save(updated, at: .project, in: f.project.scope, expectedRevision: 1); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .staleRevision) }
    }
    func testLayerOrderScalarOverridesBudgetsAndAllowlistsOnlyTighten() async throws {
        let f = try await Fixture(profile: .init(modelIdentifier: "agent-model", maximumSteps: 70, timeoutSeconds: 8_000)); defer { f.cleanup() }
        _ = try await f.store.save(ExecutionConfigurationDraft(settings: ExecutionSettings(modelIdentifier: "workspace-model", maximumSteps: 50,
            timeoutSeconds: 120, maximumOutputBytes: 2_000, allowedModelIdentifiers: ["agent-model", "run-model"], allowedEnvironmentIDs: [f.environment.id])),
            at: .workspace, in: f.project.scope, expectedRevision: nil)
        _ = try await f.save(ExecutionSettings(maximumSteps: 90, timeoutSeconds: 500))
        let run = ExecutionSettings(modelIdentifier: "run-model", maximumSteps: 100, timeoutSeconds: 1_000, maximumOutputBytes: 5_000)
        let result = try await f.store.preview(for: f.agent, in: f.project.scope, workflow: .init(maximumSteps: 20), run: run)
        XCTAssertEqual(result.modelIdentifier, "run-model"); XCTAssertEqual(result.maximumSteps, 20)
        XCTAssertEqual(result.timeoutSeconds, 120); XCTAssertEqual(result.maximumOutputBytes, 2_000)
        XCTAssertEqual(result.origins["modelIdentifier"], .run); XCTAssertEqual(result.origins["maximumSteps"], .workflow)
        XCTAssertEqual(result.origins["timeoutSeconds"], .workspace)
        XCTAssertEqual(result.sources.map(\.layer), [.global, .workspace, .project, .environment, .agent, .workflow, .run])
        for source in result.sources { XCTAssertEqual(source.fingerprint, try .canonical(source.settings)) }
        for denied in [ExecutionSettings(modelIdentifier: "unlisted"), ExecutionSettings(allowedModelIdentifiers: []), ExecutionSettings(allowedEnvironmentIDs: [])] {
            do { _ = try await f.store.preview(for: f.agent, in: f.project.scope, run: denied); XCTFail("Restriction ignored") }
            catch { XCTAssertTrue([ExecutionConfigurationError.modelDenied, .environmentDenied].contains(error as? ExecutionConfigurationError ?? .invalidConfiguration)) }
        }
    }
    func testProviderDefaultCannotEvadeModelAllowlistAndGlobalTimeoutCapsOldProfiles() async throws {
        let f = try await Fixture(profile: .init(timeoutSeconds: 86_400)); defer { f.cleanup() }
        _ = try await f.save(ExecutionSettings(allowedModelIdentifiers: ["explicit-model"]))
        do { _ = try await f.store.preview(for: f.agent, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .modelDenied) }
        let result = try await f.store.preview(for: f.agent, in: f.project.scope, run: .init(modelIdentifier: "explicit-model"))
        XCTAssertEqual(result.timeoutSeconds, 3_600); XCTAssertEqual(result.origins["timeoutSeconds"], .global)
    }
    func testEnvironmentConstraintsAndReadOnlyCeilingsCannotBeWidened() async throws {
        let f = try await Fixture(profile: .init(requestedAccess: .workspaceWrite)); defer { f.cleanup() }
        var environment = f.environment; environment.kind = .production
        environment.constraints = .init(accessCeiling: .readOnly)
        _ = try await f.store.save(.init(environments: [environment], defaultEnvironmentID: environment.id), at: .project, in: f.project.scope, expectedRevision: nil)
        do { _ = try await f.store.preview(for: f.agent, in: f.project.scope, run: .init(accessCeiling: .workspaceWrite)); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .accessDenied) }
        do { _ = try await f.store.preview(for: f.agent, in: f.project.scope, environmentID: EnvironmentID()); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .unavailableEnvironment) }
    }
    func testOutputContractIsInheritedAndConflictingOverrideFails() async throws {
        let schema = OutputSchema.object(["ok": .boolean])
        let f = try await Fixture(profile: .init(maximumOutputBytes: 1_000, outputSchema: schema)); defer { f.cleanup() }
        _ = try await f.save(.init(outputSchema: schema))
        let result = try await f.store.preview(for: f.agent, in: f.project.scope, run: .init(maximumOutputBytes: 2_000, outputSchema: schema))
        XCTAssertEqual(result.maximumOutputBytes, 1_000); XCTAssertEqual(result.outputSchema, schema)
        XCTAssertEqual(result.origins["outputSchema"], .project)
        do { _ = try await f.store.preview(for: f.agent, in: f.project.scope, run: .init(outputSchema: .object([:]))); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .conflictingOutputSchema) }
    }
    func testForeignScopesDisabledAgentsAndMalformedEnvironmentReferencesFail() async throws {
        let f = try await Fixture(); defer { f.cleanup() }; _ = try await f.save()
        let foreign = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        do { _ = try await f.store.configuration(at: .project, in: foreign); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .scopeMismatch) }
        var draft = f.agent.draft; draft.enabled = false
        let disabled = try await f.agents.update(f.agent.id, in: f.project.scope, expectedRevision: 1, draft: draft)
        do { _ = try await f.store.preview(for: disabled, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .disabledAgent) }
        let env = ProjectEnvironment(scope: foreign, name: "Foreign")
        XCTAssertThrowsError(try ExecutionConfigurationDraft(environments: [env]).validate(at: .project, in: f.project.scope))
        XCTAssertThrowsError(try ExecutionConfigurationDraft(environments: [f.environment]).validate(at: .workspace, in: f.project.scope))
        XCTAssertThrowsError(try ExecutionConfigurationDraft(environments: [f.environment], defaultEnvironmentID: EnvironmentID()).validate(at: .project, in: f.project.scope))
        var inactive = f.environment; inactive.enabled = false
        XCTAssertThrowsError(try ExecutionConfigurationDraft(environments: [inactive], defaultEnvironmentID: inactive.id).validate(at: .project, in: f.project.scope))
    }
    func testWorkspaceInheritanceStaysWithinOwnerAndProjectEnvironmentDoesNotLeak() async throws {
        let f = try await Fixture(); defer { f.cleanup() }; _ = try await f.save()
        _ = try await f.store.save(.init(settings: .init(timeoutSeconds: 60)), at: .workspace, in: f.project.scope, expectedRevision: nil)
        let sibling = try await f.catalog.createProject(in: f.project.workspaceID, name: "Sibling")
        let siblingStore = try await f.catalog.executionConfigurationStore(in: sibling.scope)
        let inherited = try await siblingStore.configuration(at: .workspace, in: sibling.scope)
        XCTAssertEqual(inherited?.draft.settings.timeoutSeconds, 60)
        let empty = try await siblingStore.configuration(at: .project, in: sibling.scope); XCTAssertNil(empty)
        let other = try await f.catalog.createWorkspace(name: "Other")
        let otherProject = try await f.catalog.createProject(in: other.id, name: "Other project")
        let otherStore = try await f.catalog.executionConfigurationStore(in: otherProject.scope)
        let otherConfiguration = try await otherStore.configuration(at: .workspace, in: otherProject.scope); XCTAssertNil(otherConfiguration)
        do { _ = try await otherStore.preview(for: f.agent, in: otherProject.scope); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .scopeMismatch) }
    }
    func testOrphanVersionsArePreservedAndSymlinksCorruptPointersAndCancellationFail() async throws {
        let f = try await Fixture(); defer { f.cleanup() }; let first = try await f.save()
        let directory = f.projectRoot.appendingPathComponent("Execution")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("Versions/1"), to: directory.appendingPathComponent("Versions/2"))
        let next = try await f.store.save(first.draft, at: .project, in: f.project.scope, expectedRevision: 1)
        XCTAssertEqual(next.revision, 3)
        let cancelled = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await f.store.save(first.draft, at: .project, in: f.project.scope, expectedRevision: 3)
        }
        do { try await cancelled.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let current = try await f.store.configuration(at: .project, in: f.project.scope); XCTAssertEqual(current?.revision, 3)
        let file = directory.appendingPathComponent("Versions/3/execution.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: directory.appendingPathComponent("Versions/1/execution.json"))
        do { _ = try await f.store.configuration(at: .project, in: f.project.scope); XCTFail() } catch { XCTAssertEqual(error as? ScopedFileError, .unsafeFile) }
        try Data(#"{"schemaVersion":999}"#.utf8).write(to: directory.appendingPathComponent("current.json"))
        do { _ = try await f.store.configuration(at: .project, in: f.project.scope); XCTFail() } catch { XCTAssertEqual(error as? ExecutionConfigurationError, .invalidConfiguration) }
    }
    func testLegacyAgentProfilesDecodeAndAdvancedFieldsSurviveOrdinaryEdits() async throws {
        let legacy = Data(#"{"modelIdentifier":"legacy-model","requestedAccess":"readOnly","maximumSteps":20,"timeoutSeconds":600}"#.utf8)
        let old = try JSONDecoder().decode(CodexAgentProfile.self, from: legacy)
        XCTAssertNil(old.outputSchema); XCTAssertNil(old.allowedEnvironmentIDs); XCTAssertNil(old.maximumOutputBytes)
        let profile = CodexAgentProfile(maximumOutputBytes: 400, allowedEnvironmentIDs: [EnvironmentID()], outputSchema: .object(["ok": .boolean]))
        let f = try await Fixture(profile: profile); defer { f.cleanup() }
        var draft = f.agent.draft; draft.name = "Renamed"
        let updated = try await f.agents.update(f.agent.id, in: f.project.scope, expectedRevision: 1, draft: draft)
        XCTAssertEqual(updated.definition.profile, profile)
        let reopened = try await f.agents.agent(f.agent.id, in: f.project.scope)
        XCTAssertEqual(reopened.definition.profile, profile)
    }
    func testMisspelledRestrictionsDuplicateKeysAndInvalidValuesCannotBecomeDefaults() async throws {
        for text in [#"{"allowedModels":["safe"]}"#, #"{"maximumSteps":0}"#, #"{"timeoutSeconds":86401}"#,
                     #"{"allowedModelIdentifiers":["one","one"]}"#, #"{"modelIdentifier":"--unsafe flag"}"#] {
            XCTAssertThrowsError(try JSONDecoder().decode(ExecutionSettings.self, from: Data(text.utf8)))
        }
        let f = try await Fixture(); defer { f.cleanup() }; _ = try await f.save()
        let file = f.projectRoot.appendingPathComponent("Execution/Versions/1/execution.json")
        let original = try String(contentsOf: file, encoding: .utf8)
        let duplicate = original.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 1, \"schemaVersion\" : 1")
        XCTAssertNotEqual(original, duplicate)
        try Data(duplicate.utf8).write(to: file)
        do { _ = try await f.store.configuration(at: .project, in: f.project.scope); XCTFail() }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .invalidConfiguration) }
    }

    func testStoredPoliciesKeepExactScopeProductionKindAndWorkspaceLock() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        func policy(_ level: PolicyLevel, environmentID: EnvironmentID? = nil) throws -> PolicyDocument {
            try PolicyDocument(level: level, workspaceID: f.project.workspaceID, projectID: level == .workspace ? nil : f.project.id,
                               environmentID: environmentID, rules: [PolicyRule(.runReadOnlyAgent, .allow)])
        }
        let workspace = try policy(.workspace), project = try policy(.project)
        var environment = f.environment; environment.kind = .production
        environment.policy = try policy(.environment, environmentID: environment.id)
        _ = try await f.store.save(.init(policy: workspace, workspaceLocked: true), at: .workspace, in: f.project.scope, expectedRevision: nil)
        _ = try await f.store.save(.init(environments: [environment], defaultEnvironmentID: environment.id, policy: project), at: .project, in: f.project.scope, expectedRevision: nil)
        let preview = try await f.store.preview(for: f.agent, in: f.project.scope)
        XCTAssertEqual(preview.policy.workspace, workspace); XCTAssertEqual(preview.policy.project, project)
        XCTAssertEqual(preview.policy.environment, environment.policy); XCTAssertEqual(preview.policy.environmentKind, .production)
        XCTAssertTrue(preview.policy.workspaceLocked)
        let reopened = try await f.catalog.executionConfigurationStore(in: f.project.scope)
        let repeated = try await reopened.preview(for: f.agent, in: f.project.scope)
        XCTAssertEqual(try preview.policy.fingerprint, try repeated.policy.fingerprint)
        XCTAssertEqual(try preview.fingerprint, try repeated.fingerprint)
        let tighter = try await f.store.preview(for: f.agent, in: f.project.scope, run: .init(timeoutSeconds: 5))
        XCTAssertNotEqual(try preview.fingerprint, try tighter.fingerprint)
        XCTAssertThrowsError(try ExecutionConfigurationDraft(policy: project).validate(at: .workspace, in: f.project.scope))
        XCTAssertThrowsError(try ExecutionConfigurationDraft(workspaceLocked: true).validate(at: .project, in: f.project.scope))
        environment.policy = try policy(.environment, environmentID: EnvironmentID())
        XCTAssertThrowsError(try environment.validate(in: f.project.scope))
    }
    func testOmittedPoliciesDenyAndHaveDeterministicScopedFingerprints() async throws {
        let f = try await Fixture(); defer { f.cleanup() }; _ = try await f.save()
        let first = try await f.store.preview(for: f.agent, in: f.project.scope)
        let second = try await f.store.preview(for: f.agent, in: f.project.scope)
        XCTAssertEqual(try first.policy.fingerprint, try second.policy.fingerprint)
        for document in [first.policy.workspace, first.policy.project, first.policy.environment] {
            XCTAssertTrue(PolicyOperation.allCases.allSatisfy { document.disposition(for: $0) == .deny })
        }
        XCTAssertEqual(first.policy.scope, f.project.scope); XCTAssertEqual(first.policy.environmentID, f.environment.id)
        XCTAssertFalse(first.policy.workspaceLocked)
    }

}
