#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDesk
@testable import AgentDeskRuntime

@MainActor
final class ProjectSetupModelTests: XCTestCase {
    @MainActor private struct Fixture {
        let root: URL
        let project: ProjectRecord
        let services: ProjectNativeServices
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let workspaces = root.appendingPathComponent("Workspaces")
            try FileManager.default.createDirectory(at: workspaces, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let catalog = try WorkspaceCatalog(container: workspaces), workspace = try await catalog.createWorkspace(name: "Synthetic")
            let project = try await catalog.createProject(in: workspace.id, name: "Synthetic Project")
            let browser = WorkspaceBrowserModel(catalog: catalog, applicationRoot: root)
            return try await Self(root: root, project: project, services: browser.executionServices(for: project))
        }
        func model() -> ProjectSetupModel { ProjectSetupModel(project: project, open: { services }) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    func testSetupReadsAndCancelledDraftDoNotSaveThenExplicitSaveReopens() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let model = f.model(); await model.load()
        XCTAssertFalse(model.isBusy); XCTAssertNil(model.repository); XCTAssertNil(model.errorMessage)
        XCTAssertNil(model.settings?.workspace); XCTAssertNil(model.settings?.project)
        let draft = try await model.draft(at: .project)
        await model.load(); XCTAssertNil(model.settings?.project)
        try await model.save(draft, at: .project, expectedRevision: nil)
        XCTAssertEqual(model.settings?.project?.revision, 1)
        let reopened = f.model(); await reopened.load()
        XCTAssertEqual(reopened.settings, model.settings)
        let saved = try await reopened.draft(at: .project); XCTAssertEqual(saved, draft)
    }
    func testStaleEditorSavePreservesNewerSettingsAndAllowsReload() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let first = f.model(), second = f.model(); await first.load(); await second.load()
        var draft = try await first.draft(at: .workspace); draft.settings.timeoutSeconds = 123
        try await first.save(draft, at: .workspace, expectedRevision: nil)
        do { try await second.save(.init(), at: .workspace, expectedRevision: nil); XCTFail("Stale editor overwrote saved settings") }
        catch { XCTAssertEqual(error as? ExecutionConfigurationError, .staleRevision) }
        XCTAssertFalse(second.isBusy)
        await second.load(); XCTAssertEqual(second.settings?.workspace?.draft.settings.timeoutSeconds, 123)
    }
    func testRegistrationVerifiesNativeBookmarkAndRemovalKeepsRepository() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let root = f.root.appendingPathComponent("Synthetic repository")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let initialized = try await MacCommandCapture.run(executable: GitExecutableLocator.installed(), arguments: ["init", "--initial-branch=main"],
            directory: root, environment: GitCaptureConfiguration.environment, timeout: .seconds(10), maximumBytes: 65_536)
        XCTAssertEqual(initialized.status, 0)
        let model = f.model(); await model.load(); await model.register(root)
        XCTAssertEqual(model.repository?.revision, 1); XCTAssertEqual(model.repositoryAccessAvailable, true); XCTAssertNil(model.errorMessage)
        let reopened = f.model(); await reopened.load()
        XCTAssertEqual(reopened.repository, model.repository); XCTAssertEqual(reopened.repositoryAccessAvailable, true)
        var active: RepositoryAccess? = try await f.services.repositories.access(in: f.project.scope)
        XCTAssertNotNil(active)
        await model.removeRepository(); XCTAssertNotNil(model.errorMessage); XCTAssertNotNil(model.repository)
        active = nil
        await model.removeRepository(); XCTAssertNil(model.repository); XCTAssertNil(model.repositoryAccessAvailable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".git/HEAD").path))
    }
    func testCancelledLoadAndForeignServiceCannotPublishSetupState() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let cancelled = f.model()
        let operation = Task { withUnsafeCurrentTask { $0?.cancel() }; await cancelled.load() }
        await operation.value; XCTAssertFalse(cancelled.isBusy); XCTAssertNil(cancelled.settings)
        await cancelled.load(); XCTAssertNotNil(cancelled.settings)
        let sibling = try await f.services.catalog.createProject(in: f.project.workspaceID, name: "Sibling")
        let foreign = ProjectSetupModel(project: sibling, open: { f.services })
        await foreign.load(); XCTAssertNil(foreign.settings); XCTAssertNotNil(foreign.errorMessage)
    }
    func testNativeStorageRejectsLinkedPrivateDirectoriesAndForeignProjectBeforeWrites() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let outside = f.root.appendingPathComponent("Unrelated")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let data = f.root.appendingPathComponent("Data")
        try FileManager.default.moveItem(at: data, to: f.root.appendingPathComponent("OriginalData"))
        try FileManager.default.createSymbolicLink(at: data, withDestinationURL: outside)
        XCTAssertThrowsError(try NativeProjectStorage.prepare(root: f.root, workspaceID: WorkspaceID()))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        let other = try await Fixture.make(); defer { other.remove() }
        let missing = f.root.appendingPathComponent("Must not create")
        let browser = WorkspaceBrowserModel(catalog: f.services.catalog, applicationRoot: missing)
        do { _ = try await browser.executionServices(for: other.project); XCTFail("Foreign project opened native storage") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
    }
}
#endif
