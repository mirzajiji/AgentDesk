import Foundation
import XCTest
@testable import AgentDeskCore

@MainActor
final class ProjectSkillStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let catalog: WorkspaceCatalog
        let project: ProjectRecord
        let store: ProjectSkillStore
        var owner: SkillScope { SkillScope(workspaceID: project.workspaceID, projectID: project.id) }
        var workspaceOwner: SkillScope { SkillScope(workspaceID: project.workspaceID) }
        var projectRoot: URL { root.appendingPathComponent("\(project.workspaceID)/Projects/\(project.id)") }
        init() async throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
            catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic workspace")
            project = try await catalog.createProject(in: workspace.id, name: "Synthetic project")
            store = try await catalog.skillStore(in: project.scope)
        }
        func cleanup() { try? FileManager.default.removeItem(at: root) }
    }
    private func draft(_ name: String = "Evidence review") -> SkillDraft {
        SkillDraft(name: name, summary: "Synthetic review instructions", instructions: "Compare observed evidence with the current requirement. Mark missing evidence explicitly.",
                   requiredPermissions: [.readEvidence], attachments: [
                    SkillAttachment(kind: .example, name: "example.md", text: "Synthetic example: expected status 200; observed status 200."),
                    SkillAttachment(kind: .script, name: "sample.sh", text: "touch SHOULD_NOT_EXECUTE\n")])
    }
    func testCRUDReopenImmutableVersionsAndInertAttachments() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let first = try await f.store.save(draft(), at: f.owner, in: f.project.scope)
        let version = f.projectRoot.appendingPathComponent("Skills/\(first.id)/Versions/1")
        let manifest = try Data(contentsOf: version.appendingPathComponent("skill.json"))
        let attributes = try FileManager.default.attributesOfItem(atPath: version.appendingPathComponent("scripts/sample.sh").path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.projectRoot.appendingPathComponent("SHOULD_NOT_EXECUTE").path))
        var changed = first.draft; changed.instructions = "Updated synthetic guidance"
        let second = try await f.store.save(changed, at: f.owner, in: f.project.scope, id: first.id, expectedRevision: 1)
        XCTAssertEqual(second.definition.revision, 2)
        let reopened = try await f.catalog.skillStore(in: f.project.scope)
        let historic = try await reopened.skill(first.definition.reference, in: f.project.scope)
        XCTAssertEqual(historic, first)
        XCTAssertEqual(try Data(contentsOf: version.appendingPathComponent("skill.json")), manifest)
        let listed = try await reopened.skills(at: f.owner, in: f.project.scope)
        XCTAssertEqual(listed, [second]); XCTAssertEqual(historic.attachments, first.attachments)
        do { _ = try await f.store.save(changed, at: f.owner, in: f.project.scope, id: first.id, expectedRevision: 1); XCTFail() }
        catch { XCTAssertEqual(error as? SkillError, .staleRevision) }
    }
    func testPinnedAgentReferencesComposeExactSourcesAndPermissionRequestsWithoutGrants() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let workspaceSkill = try await f.store.save(draft("Shared review"), at: f.workspaceOwner, in: f.project.scope)
        var projectDraft = draft(); projectDraft.requiredPermissions = [.writeProject, .externalMutation]
        let projectSkill = try await f.store.save(projectDraft, at: f.owner, in: f.project.scope)
        let agents = try await f.catalog.agentStore(in: f.project.scope)
        var agentDraft = AgentTemplate.general.draft
        agentDraft.skillReferences = try [workspaceSkill.definition.reference, projectSkill.definition.reference]
        let agent = try await agents.create(agentDraft, in: f.project.scope)
        var changed = projectSkill.draft; changed.instructions = "Later version must not replace the pin"
        _ = try await f.store.save(changed, at: f.owner, in: f.project.scope, id: projectSkill.id, expectedRevision: 1)
        let instructions = try await f.catalog.instructionStore(in: f.project.scope)
        let preview = try await instructions.preview(for: agent, in: f.project.scope)
        XCTAssertEqual(preview.sources.map(\.layer), ["Global", "Agent", "Skill", "Skill"])
        XCTAssertEqual(preview.sources.last?.revision, 1); XCTAssertEqual(preview.sources.last?.text, projectDraft.instructions)
        XCTAssertFalse(preview.text.contains(changed.instructions)); XCTAssertFalse(preview.text.contains("SHOULD_NOT_EXECUTE"))
        XCTAssertEqual(preview.sources.last?.sha256, projectSkill.definition.instructionsFingerprint.rawValue)
        XCTAssertEqual(preview.skillPermissionRequests.last?.operations, [.writeProject, .externalMutation])
        XCTAssertEqual(agent.definition.profile.requestedAccess, .readOnly)
        let configStore = try await f.catalog.executionConfigurationStore(in: f.project.scope)
        let environment = ProjectEnvironment(scope: f.project.scope, name: "Test")
        _ = try await configStore.save(.init(environments: [environment], defaultEnvironmentID: environment.id), at: .project, in: f.project.scope, expectedRevision: nil)
        let configuration = try await configStore.preview(for: agent, in: f.project.scope)
        XCTAssertEqual(configuration.policy.project.disposition(for: .writeProject), .deny)
        XCTAssertEqual(configuration.policy.project.disposition(for: .externalMutation), .deny)
        var renamed = agent.draft; renamed.name = "Renamed with pins"
        let updated = try await agents.update(agent.id, in: f.project.scope, expectedRevision: 1, draft: renamed)
        XCTAssertEqual(updated.draft.skillReferences, agentDraft.skillReferences)
    }
    func testDisabledOrArchivedCurrentVersionBlocksOldPinsAndRestoreIsExplicit() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let skill = try await f.store.save(draft(), at: f.owner, in: f.project.scope)
        let agents = try await f.catalog.agentStore(in: f.project.scope)
        var agentDraft = AgentTemplate.general.draft; agentDraft.skillReferences = try [skill.definition.reference]
        let agent = try await agents.create(agentDraft, in: f.project.scope)
        let instructions = try await f.catalog.instructionStore(in: f.project.scope)
        _ = try await f.store.setArchived(true, for: skill.id, at: f.owner, in: f.project.scope, expectedRevision: 1)
        do { _ = try await instructions.preview(for: agent, in: f.project.scope); XCTFail() } catch { XCTAssertEqual(error as? SkillError, .unavailable) }
        do { _ = try await f.store.save(skill.draft, at: f.owner, in: f.project.scope, id: skill.id, expectedRevision: 2); XCTFail() } catch { XCTAssertEqual(error as? SkillError, .unavailable) }
        let hidden = try await f.store.skills(at: f.owner, in: f.project.scope); XCTAssertTrue(hidden.isEmpty)
        let restored = try await f.store.setArchived(false, for: skill.id, at: f.owner, in: f.project.scope, expectedRevision: 2)
        XCTAssertEqual(restored.definition.revision, 3)
        _ = try await instructions.preview(for: agent, in: f.project.scope)
        var disabled = restored.draft; disabled.enabled = false
        _ = try await f.store.save(disabled, at: f.owner, in: f.project.scope, id: skill.id, expectedRevision: 3)
        do { _ = try await instructions.preview(for: agent, in: f.project.scope); XCTFail() } catch { XCTAssertEqual(error as? SkillError, .unavailable) }
        // A broken reference can be removed without losing the agent's own instructions/history.
        var repaired = agent.draft; repaired.skillReferences = []
        _ = try await agents.update(agent.id, in: f.project.scope, expectedRevision: 1, draft: repaired)
    }
    func testWorkspaceSharingAndForeignProjectWorkspaceOrRequestScopeAreRejected() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let shared = try await f.store.save(draft(), at: f.workspaceOwner, in: f.project.scope)
        let local = try await f.store.save(draft(), at: f.owner, in: f.project.scope)
        let sibling = try await f.catalog.createProject(in: f.project.workspaceID, name: "Sibling")
        let store = try await f.catalog.skillStore(in: sibling.scope)
        let sharedRead = try await store.skill(shared.definition.reference, in: sibling.scope); XCTAssertEqual(sharedRead, shared)
        do { _ = try await store.skill(local.definition.reference, in: sibling.scope); XCTFail() } catch { XCTAssertEqual(error as? SkillError, .scopeMismatch) }
        do { _ = try await f.store.skills(at: f.owner, in: sibling.scope); XCTFail() } catch { XCTAssertEqual(error as? SkillError, .scopeMismatch) }
        let other = try await f.catalog.createWorkspace(name: "Other company")
        let otherProject = try await f.catalog.createProject(in: other.id, name: "Other project")
        let otherStore = try await f.catalog.skillStore(in: otherProject.scope)
        do { _ = try await otherStore.skill(shared.definition.reference, in: otherProject.scope); XCTFail() } catch { XCTAssertEqual(error as? SkillError, .scopeMismatch) }
        let agents = try await f.catalog.agentStore(in: sibling.scope)
        var draft = AgentTemplate.general.draft; draft.skillReferences = try [local.definition.reference]
        do { _ = try await agents.create(draft, in: sibling.scope); XCTFail() } catch { XCTAssertEqual(error as? SkillError, .scopeMismatch) }
    }
    func testInvalidReferencesPermissionsBundleLimitsPathsAndDuplicateNamesFail() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let skill = try await f.store.save(draft(), at: f.owner, in: f.project.scope)
        do { _ = try await f.store.save(draft("evidence REVIEW"), at: f.owner, in: f.project.scope); XCTFail() } catch { XCTAssertEqual(error as? SkillError, .duplicateName) }
        for name in ["../escape", "/absolute", "hidden/child", ".hidden", "a\\b", "sibling-prefix/escape", "a%2fb"] {
            var invalid = draft(); invalid.attachments = [.init(kind: .script, name: name, text: "Synthetic")]
            XCTAssertThrowsError(try invalid.validated(), name)
        }
        var duplicate = draft(); duplicate.requiredPermissions = [.readEvidence, .readEvidence]; XCTAssertThrowsError(try duplicate.validated())
        var files = draft(); files.attachments += [.init(kind: .example, name: "EXAMPLE.md", text: "Duplicate")]; XCTAssertThrowsError(try files.validated())
        var oversized = draft(); oversized.instructions = String(repeating: "x", count: 65_537); XCTAssertThrowsError(try oversized.validated())
        let agents = try await f.catalog.agentStore(in: f.project.scope)
        var invalid = AgentTemplate.general.draft
        invalid.skillReferences = try [skill.definition.reference, SkillReference(scope: f.owner, id: skill.id, revision: 2)]
        XCTAssertThrowsError(try invalid.validated())
        invalid.skillReferences = try [SkillReference(scope: f.owner, id: skill.id, revision: 999)]
        do { _ = try await agents.create(invalid, in: f.project.scope); XCTFail() } catch { XCTAssertEqual(error as? ScopedFileError, .notFound) }
        let empty = try await agents.agents(in: f.project.scope); XCTAssertTrue(empty.isEmpty)
        XCTAssertThrowsError(try SkillReference(scope: f.owner, id: skill.id, revision: 0))
    }
    func testTamperedBytesSymlinksHardlinksAndManifestPathEscapesFailClosed() async throws {
        for attack in ["bytes", "symlink", "hardlink", "path", "scope", "unknown", "duplicate"] {
            let f = try await Fixture(); defer { f.cleanup() }
            let skill = try await f.store.save(draft(), at: f.owner, in: f.project.scope)
            let version = f.projectRoot.appendingPathComponent("Skills/\(skill.id)/Versions/1")
            let file = version.appendingPathComponent("instructions.md")
            if attack == "bytes" { try Data("Changed without a revision".utf8).write(to: file) }
            else if attack == "symlink" {
                try FileManager.default.removeItem(at: file)
                try FileManager.default.createSymbolicLink(at: file, withDestinationURL: version.appendingPathComponent("examples/example.md"))
            } else if attack == "hardlink" {
                try FileManager.default.linkItem(at: file, to: version.appendingPathComponent("alias.md"))
            } else {
                let manifest = version.appendingPathComponent("skill.json")
                let text = try String(contentsOf: manifest, encoding: .utf8)
                let changed: String
                switch attack {
                case "path": changed = text.replacingOccurrences(of: "examples/example.md", with: "../example.md")
                case "unknown": changed = text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 1, \"autoRun\" : true")
                case "duplicate": changed = text.replacingOccurrences(of: "\"schemaVersion\" : 1", with: "\"schemaVersion\" : 1, \"schemaVersion\" : 1")
                default: changed = text.replacingOccurrences(of: f.project.id.rawValue, with: ProjectID().rawValue)
                }
                XCTAssertNotEqual(changed, text)
                try Data(changed.utf8).write(to: manifest)
            }
            do { _ = try await f.store.skill(skill.definition.reference, in: f.project.scope); XCTFail(attack) }
            catch { XCTAssertTrue(error is SkillError || error is ScopedFileError, attack) }
        }
    }
    func testOrphanVersionsCancellationAndMalformedPointerPreservePriorData() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let skill = try await f.store.save(draft(), at: f.owner, in: f.project.scope)
        let directory = f.projectRoot.appendingPathComponent("Skills/\(skill.id)")
        try FileManager.default.copyItem(at: directory.appendingPathComponent("Versions/1"), to: directory.appendingPathComponent("Versions/2"))
        let next = try await f.store.save(skill.draft, at: f.owner, in: f.project.scope, id: skill.id, expectedRevision: 1)
        XCTAssertEqual(next.definition.revision, 3)
        let cancelled = Task { () throws -> Void in
            withUnsafeCurrentTask { $0?.cancel() }
            _ = try await f.store.save(skill.draft, at: f.owner, in: f.project.scope, id: skill.id, expectedRevision: 3)
        }
        do { try await cancelled.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        let historic = try await f.store.skill(skill.definition.reference, in: f.project.scope); XCTAssertEqual(historic, skill)
        try Data(#"{"schemaVersion":999}"#.utf8).write(to: directory.appendingPathComponent("current.json"))
        do { _ = try await f.store.skills(at: f.owner, in: f.project.scope); XCTFail() } catch { XCTAssertEqual(error as? SkillError, .invalidBundle) }
    }
    func testExpandedAgentMetadataCannotPublishARevisionThatCannotBeRead() async throws {
        let f = try await Fixture(); defer { f.cleanup() }
        let skill = try await f.store.save(draft(), at: f.owner, in: f.project.scope)
        let agents = try await f.catalog.agentStore(in: f.project.scope)
        let agent = try await agents.create(AgentTemplate.general.draft, in: f.project.scope)
        var edited = agent.draft; edited.skillReferences = try [skill.definition.reference]
        let choices = (0..<64).map { "synthetic-value-00000-\($0)" }
        edited.profile.outputSchema = .object(Dictionary(uniqueKeysWithValues: (0..<32).map { ("field\($0)", OutputSchema.string(minimum: 0, maximum: 40, choices: choices)) }))
        XCTAssertNoThrow(try edited.profile.outputSchema!.jsonData())
        do { _ = try await agents.update(agent.id, in: f.project.scope, expectedRevision: 1, draft: edited); XCTFail() }
        catch { XCTAssertEqual(error as? AgentConfigurationError, .invalidConfiguration) }
        let current = try await agents.agent(agent.id, in: f.project.scope)
        XCTAssertEqual(current, agent)
        let directory = f.projectRoot.appendingPathComponent("Agents/\(agent.id)/Versions")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path), ["1"])
    }

    func testAttachmentEditorKeepsUnfinishedDraftAndRejectsInvalidEditsAtomically() throws {
        var draft = SkillDraft(name: "", instructions: "")
        try draft.setAttachment(.init(kind: .example, name: "example.md", text: "Synthetic example"))
        let before = draft
        XCTAssertThrowsError(try draft.setAttachment(.init(kind: .script, name: "../escape", text: "Synthetic"), at: 0))
        XCTAssertEqual(draft, before)
        XCTAssertThrowsError(try draft.setAttachment(.init(kind: .example, name: "EXAMPLE.md", text: "Duplicate")))
        XCTAssertEqual(draft, before)
        XCTAssertThrowsError(try draft.setAttachment(.init(kind: .script, name: "safe.sh", text: "Synthetic"), at: 99))
        try draft.setAttachment(.init(kind: .script, name: "safe.sh", text: "Synthetic inert script"), at: 0)
        XCTAssertEqual(draft.name, ""); XCTAssertEqual(draft.instructions, ""); XCTAssertEqual(draft.attachments.first?.relativeFile, "scripts/safe.sh")
    }

}
