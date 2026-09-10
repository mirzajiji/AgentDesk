#if os(macOS)
import AgentDeskCore
import AgentDeskRuntime
import Foundation
import XCTest
@testable import AgentDesk

@MainActor
final class ProjectRunContextModelTests: XCTestCase {
    func testHistoryCanOpenWithoutTaskReviewOrCreatingRunDatabase() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let model = f.model(); await model.load(); model.selectedAgentID = f.agent.id
        XCTAssertNil(model.presentation)
        let archive = try await model.archive(), runs = try await archive.runs()
        XCTAssertTrue(runs.isEmpty); XCTAssertNil(model.presentation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.services.database.path))
        model.selectedAgentID = nil
        do { _ = try await model.archive(); XCTFail("History opened without selected agent") } catch {}
    }
    @MainActor private struct Fixture {
        let root: URL
        let project: ProjectRecord
        let agent: AgentSnapshot
        let services: ProjectNativeServices
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let workspaces = root.appendingPathComponent("Workspaces")
            try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let catalog = try WorkspaceCatalog(container: workspaces)
            let workspace = try await catalog.createWorkspace(name: "Synthetic")
            let project = try await catalog.createProject(in: workspace.id, name: "Synthetic project")
            let services = try await WorkspaceBrowserModel(catalog: catalog, applicationRoot: root).executionServices(for: project)
            for level in [ExecutionConfigurationLevel.workspace, .project] {
                let proposal = try await services.setup.proposedDefaults(at: level)
                _ = try await services.setup.save(proposal, at: level, expectedRevision: nil)
            }
            let agent = try await catalog.agentStore(in: project.scope).create(.init(name: "Synthetic agent",
                instructions: "Inspect synthetic evidence.\npassword=synthetic-context-secret"), in: project.scope)
            return Self(root: root, project: project, agent: agent, services: services)
        }
        func model() -> ProjectRunContextModel { .init(project: project, open: { services }) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    func testContextReviewRequiresSelectionRedactsDisplayAndCreatesNoRun() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let model = f.model(); await model.load()
        XCTAssertNil(model.selectedAgentID); XCTAssertNil(model.presentation)
        await model.preview(); XCTAssertNil(model.presentation)
        model.selectedAgentID = f.agent.id; await model.preview()
        let presentation = try XCTUnwrap(model.presentation)
        XCTAssertEqual(presentation.scope, f.project.scope)
        XCTAssertFalse(presentation.instructions.contains("synthetic-context-secret"))
        XCTAssertTrue(presentation.instructions.contains("[REDACTED]"))
        XCTAssertTrue(presentation.sources.contains("version 1"))
        let context = try await model.contextForPreparation()
        XCTAssertEqual(context.agent.id, f.agent.id)
        XCTAssertTrue(context.instructions.text.contains("synthetic-context-secret"), "Redaction must not mutate authoritative instructions")
        XCTAssertFalse(FileManager.default.fileExists(atPath: f.services.database.path))
    }

    func testStaleSourceAndChangedSelectionInvalidateReviewedContext() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let model = f.model(); await model.load(); model.selectedAgentID = f.agent.id; await model.preview()
        var draft = f.agent.draft; draft.instructions = "Updated synthetic evidence instructions"
        _ = try await f.services.catalog.agentStore(in: f.project.scope).update(f.agent.id, in: f.project.scope,
            expectedRevision: f.agent.definition.revision, draft: draft)
        do { _ = try await model.contextForPreparation(); XCTFail("Stale source accepted") }
        catch { XCTAssertEqual(error as? ExecutionSetupError, .staleContext) }
        XCTAssertNil(model.presentation)
        await model.preview(); XCTAssertTrue(model.presentation?.instructions.contains(draft.instructions) == true)
        model.selectedEnvironmentID = EnvironmentID()
        XCTAssertNil(model.presentation)
        await model.preview(); XCTAssertNotNil(model.errorMessage); XCTAssertNil(model.presentation)
        do { _ = try await model.contextForPreparation(); XCTFail("Invalid selection accepted") } catch {}
    }

    func testForeignServicesAndCancelledLoadingDoNotPublishContext() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let other = try await f.services.catalog.createProject(in: f.project.workspaceID, name: "Other synthetic project")
        let foreign = ProjectRunContextModel(project: other, open: { f.services })
        await foreign.load(); XCTAssertTrue(foreign.agents.isEmpty); XCTAssertNil(foreign.services); XCTAssertNotNil(foreign.errorMessage)
        let model = f.model()
        let cancelled = Task { withUnsafeCurrentTask { $0?.cancel() }; await model.load() }
        await cancelled.value
        XCTAssertTrue(model.agents.isEmpty); XCTAssertNil(model.presentation); XCTAssertFalse(model.isBusy)
        await model.load(); XCTAssertEqual(model.agents.map(\.id), [f.agent.id])
    }
}
#endif
