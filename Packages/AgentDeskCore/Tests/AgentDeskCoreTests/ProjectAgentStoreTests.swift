import Foundation
import XCTest
@testable import AgentDeskCore

final class ProjectAgentStoreTests: XCTestCase {
    private struct Fixture: Sendable {
        let container: URL
        let catalog: WorkspaceCatalog
        let project: ProjectRecord
        let store: ProjectAgentStore
        var projectRoot: URL { container.appendingPathComponent("\(project.workspaceID)/Projects/\(project.id)") }
        init() async throws {
            container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            catalog = try WorkspaceCatalog(container: container)
            let workspace = try await catalog.createWorkspace(name: "Synthetic Workspace")
            project = try await catalog.createProject(in: workspace.id, name: "Synthetic Project")
            store = try await catalog.agentStore(in: project.scope)
        }
        func cleanup() { try? FileManager.default.removeItem(at: container) }
    }

    @MainActor
    func testCreateUpdateAndReopenPreserveOriginalInstructionVersion() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let original = try await fixture.store.create(AgentTemplate.general.draft, in: fixture.project.scope)
        let path = fixture.projectRoot.appendingPathComponent("Agents/\(original.id)/Versions/1/instructions.md")
        let bytes = try Data(contentsOf: path)
        var edited = original.draft; edited.name = "Project Assistant"; edited.instructions = "Updated synthetic instructions."
        let updated = try await fixture.store.update(original.id, in: fixture.project.scope, expectedRevision: 1, draft: edited)
        XCTAssertEqual(updated.definition.revision, 2)
        XCTAssertEqual(updated.definition.createdAt, original.definition.createdAt)
        XCTAssertEqual(try Data(contentsOf: path), bytes)
        let reopened = try await fixture.catalog.agentStore(in: fixture.project.scope)
        let current = try await reopened.agent(original.id, in: fixture.project.scope)
        let historical = try await reopened.agent(original.id, in: fixture.project.scope, revision: 1)
        XCTAssertEqual(current, updated); XCTAssertEqual(historical, original)
        let list = try await reopened.agents(in: fixture.project.scope)
        XCTAssertEqual(list, [updated])
    }

    @MainActor
    func testArchiveRestoreAndNameReusePreserveHistory() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let original = try await fixture.store.create(AgentTemplate.general.draft, in: fixture.project.scope)
        let archived = try await fixture.store.setArchived(true, for: original.id, in: fixture.project.scope, expectedRevision: 1)
        let active = try await fixture.store.agents(in: fixture.project.scope); XCTAssertTrue(active.isEmpty)
        let all = try await fixture.store.agents(in: fixture.project.scope, includeArchived: true); XCTAssertEqual(all, [archived])
        do {
            _ = try await fixture.store.update(original.id, in: fixture.project.scope, expectedRevision: 2, draft: original.draft)
            XCTFail("Archived edit accepted")
        } catch { XCTAssertEqual(error as? AgentConfigurationError, .archived) }
        let replacement = try await fixture.store.create(original.draft, in: fixture.project.scope)
        do {
            _ = try await fixture.store.setArchived(false, for: original.id, in: fixture.project.scope, expectedRevision: 2)
            XCTFail("Duplicate restoration")
        } catch { XCTAssertEqual(error as? AgentConfigurationError, .duplicateName) }
        _ = try await fixture.store.setArchived(true, for: replacement.id, in: fixture.project.scope, expectedRevision: 1)
        let restored = try await fixture.store.setArchived(false, for: original.id, in: fixture.project.scope, expectedRevision: 2)
        XCTAssertFalse(restored.definition.archived)
        let historical = try await fixture.store.agent(original.id, in: fixture.project.scope, revision: 1)
        XCTAssertEqual(historical, original)
    }

    @MainActor
    func testStaleEditLeavesLatestVersionIntact() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let original = try await fixture.store.create(AgentTemplate.general.draft, in: fixture.project.scope)
        var disabled = original.draft; disabled.enabled = false
        let current = try await fixture.store.update(original.id, in: fixture.project.scope, expectedRevision: 1, draft: disabled)
        do {
            _ = try await fixture.store.update(original.id, in: fixture.project.scope, expectedRevision: 1, draft: original.draft)
            XCTFail("Stale edit accepted")
        } catch { XCTAssertEqual(error as? AgentConfigurationError, .staleRevision) }
        let actual = try await fixture.store.agent(original.id, in: fixture.project.scope)
        XCTAssertEqual(actual, current)
    }

    @MainActor
    func testDuplicateNamesAreProjectScopedAndCaseInsensitive() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        _ = try await fixture.store.create(AgentTemplate.general.draft, in: fixture.project.scope)
        var duplicate = AgentTemplate.general.draft; duplicate.name = " general assistant "
        do { _ = try await fixture.store.create(duplicate, in: fixture.project.scope); XCTFail("Duplicate accepted") }
        catch { XCTAssertEqual(error as? AgentConfigurationError, .duplicateName) }
        let otherProject = try await fixture.catalog.createProject(in: fixture.project.workspaceID, name: "Second")
        let other = try await fixture.catalog.agentStore(in: otherProject.scope)
        _ = try await other.create(duplicate, in: otherProject.scope)
    }

    @MainActor
    func testForeignScopeAndCopiedAgentAreRejected() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let agent = try await fixture.store.create(AgentTemplate.general.draft, in: fixture.project.scope)
        let otherProject = try await fixture.catalog.createProject(in: fixture.project.workspaceID, name: "Second")
        let other = try await fixture.catalog.agentStore(in: otherProject.scope)
        do { _ = try await fixture.store.agent(agent.id, in: otherProject.scope); XCTFail("Foreign read") }
        catch { XCTAssertEqual(error as? ScopedFileError, .scopeMismatch) }
        do { _ = try await fixture.store.create(agent.draft, in: otherProject.scope); XCTFail("Foreign create") }
        catch { XCTAssertEqual(error as? ScopedFileError, .scopeMismatch) }
        let source = fixture.projectRoot.appendingPathComponent("Agents")
        let destination = fixture.container.appendingPathComponent("\(otherProject.workspaceID)/Projects/\(otherProject.id)/Agents")
        try FileManager.default.copyItem(at: source, to: destination)
        do { _ = try await other.agents(in: otherProject.scope); XCTFail("Copied scope accepted") }
        catch { XCTAssertEqual(error as? AgentConfigurationError, .invalidConfiguration) }
    }

    @MainActor
    func testConcurrentStoresSharingCatalogCannotCreateDuplicateAgents() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let other = try await fixture.catalog.agentStore(in: fixture.project.scope)
        let successes = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for store in [fixture.store, other] {
                group.addTask { (try? await store.create(AgentTemplate.general.draft, in: fixture.project.scope)) != nil }
            }
            var count = 0
            for await result in group { if result { count += 1 } }
            return count
        }
        XCTAssertEqual(successes, 1)
        let agents = try await fixture.store.agents(in: fixture.project.scope); XCTAssertEqual(agents.count, 1)
    }

    @MainActor
    func testUnpublishedVersionIsNotOverwrittenOnNextSave() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let agent = try await fixture.store.create(AgentTemplate.general.draft, in: fixture.project.scope)
        let orphan = fixture.projectRoot.appendingPathComponent("Agents/\(agent.id)/Versions/2")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: false)
        let evidence = Data("Unpublished synthetic evidence".utf8)
        try evidence.write(to: orphan.appendingPathComponent("preserved.md"))
        let next = try await fixture.store.update(agent.id, in: fixture.project.scope, expectedRevision: 1, draft: agent.draft)
        XCTAssertEqual(next.definition.revision, 3)
        XCTAssertEqual(try Data(contentsOf: orphan.appendingPathComponent("preserved.md")), evidence)
    }

    @MainActor
    func testSymlinkedInstructionsAndInvalidPointersFailClosed() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let agent = try await fixture.store.create(AgentTemplate.general.draft, in: fixture.project.scope)
        let root = fixture.projectRoot.appendingPathComponent("Agents/\(agent.id)")
        let instructions = root.appendingPathComponent("Versions/1/instructions.md")
        let outside = fixture.container.appendingPathComponent("synthetic-outside.md")
        try Data("Outside evidence".utf8).write(to: outside)
        try FileManager.default.removeItem(at: instructions)
        try FileManager.default.createSymbolicLink(at: instructions, withDestinationURL: outside)
        do { _ = try await fixture.store.agent(agent.id, in: fixture.project.scope); XCTFail("Symlink read") }
        catch { XCTAssertEqual(error as? ScopedFileError, .unsafeFile) }
        let pointer = root.appendingPathComponent("current.json")
        try Data("{broken".utf8).write(to: pointer)
        do { _ = try await fixture.store.agents(in: fixture.project.scope); XCTFail("Malformed pointer") }
        catch { XCTAssertEqual(error as? AgentConfigurationError, .invalidConfiguration) }
    }

    @MainActor
    func testCancelledCreationDoesNotPublishAnAgent() async throws {
        let fixture = try await Fixture(); defer { fixture.cleanup() }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.store.create(AgentTemplate.general.draft, in: fixture.project.scope)
        }
        do { _ = try await task.value; XCTFail("Cancelled agent creation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let agents = try await fixture.store.agents(in: fixture.project.scope); XCTAssertTrue(agents.isEmpty)
    }

    func testAllTemplatesValidateAndRequestReadOnlyProviderDefaults() throws {
        XCTAssertEqual(AgentTemplate.allCases.count, 11)
        for template in AgentTemplate.allCases {
            let draft = try template.draft.validated()
            XCTAssertEqual(draft.profile.requestedAccess, .readOnly)
            XCTAssertNil(draft.profile.modelIdentifier)
            XCTAssertFalse(draft.instructions.isEmpty)
        }
    }

    func testInvalidDraftsAndProviderLimitsAreRejected() {
        var draft = AgentTemplate.general.draft
        for name in ["", "a/b", "a\u{0}b", String(repeating: "a", count: 101)] {
            draft.name = name; XCTAssertThrowsError(try draft.validated())
        }
        draft = AgentTemplate.general.draft
        for instructions in [" \n ", "a\u{0}b", String(repeating: "x", count: 65_537)] {
            draft.instructions = instructions; XCTAssertThrowsError(try draft.validated())
        }
        for profile in [CodexAgentProfile(modelIdentifier: "$(invalid)"), CodexAgentProfile(maximumSteps: 0),
                        CodexAgentProfile(timeoutSeconds: 0), CodexAgentProfile(timeoutSeconds: 86_401)] {
            XCTAssertThrowsError(try profile.validate())
        }
    }

    func testSharedDescriptorLockRejectsReentrancyAndReleasesAfterFailure() throws {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: container) }
        let directory = try ConfigurationDirectory(trustedContainer: container)
        try directory.withLock {
            XCTAssertThrowsError(try directory.withLock { 1 }) { XCTAssertEqual($0 as? CatalogError, .busy) }
        }
        XCTAssertEqual(try directory.withLock { 42 }, 42)
    }
}
