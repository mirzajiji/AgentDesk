#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class RepositoryBookmarkIntegrationTests: XCTestCase {
    func testNativeReadOnlyBookmarkPersistsReopensAndProtectsActiveRegistration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = root.appendingPathComponent("Workspaces"), records = root.appendingPathComponent("RepositoryAccess")
        let repository = root.appendingPathComponent("Repository")
        for directory in [configuration, records, repository] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let initialized = try await MacCommandCapture.run(executable: GitExecutableLocator.installed(), arguments: ["init", "--initial-branch=main"],
            directory: repository, environment: GitCaptureConfiguration.environment, timeout: .seconds(10), maximumBytes: 65_536)
        XCTAssertEqual(initialized.status, 0)
        let catalog = try WorkspaceCatalog(container: configuration), workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "Synthetic")
        let registry = try ProjectRepositoryRegistry(catalog: catalog, container: records)
        let saved = try await registry.register(repository, in: project.scope, expectedRevision: nil)
        let reopened = try ProjectRepositoryRegistry(catalog: catalog, container: records)
        var access: RepositoryAccess? = try await reopened.access(in: project.scope)
        XCTAssertEqual(access?.registration, saved)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(access?.directory).appendingPathComponent(".git/HEAD").path))
        do { try await registry.remove(in: project.scope, expectedRevision: saved.revision); XCTFail("Removed an active native grant") }
        catch { XCTAssertEqual(error as? RepositoryRegistrationError, .busy) }
        access = nil
        try await registry.remove(in: project.scope, expectedRevision: saved.revision)
        let removed = try await registry.registration(in: project.scope); XCTAssertNil(removed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.path))
    }
}
#endif
