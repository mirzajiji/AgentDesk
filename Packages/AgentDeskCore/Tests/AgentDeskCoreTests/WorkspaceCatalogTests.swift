import Darwin
import Foundation
import XCTest
@testable import AgentDeskCore

final class WorkspaceCatalogTests: XCTestCase {
    private func fixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @MainActor
    func testCreateRenameAndReopenRetainsIdentitiesAndFiles() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let empty = try await catalog.workspaces(); XCTAssertTrue(empty.isEmpty)
        let workspace = try await catalog.createWorkspace(name: "  Synthetic Studio  ")
        let project = try await catalog.createProject(in: workspace.id, name: "Native App")
        let renamed = try await catalog.renameWorkspace(workspace.id, name: "Personal")
        let renamedProject = try await catalog.renameProject(project.scope, name: "Desktop")
        XCTAssertEqual(renamed.id, workspace.id)
        XCTAssertEqual(renamed.createdAt, workspace.createdAt)
        XCTAssertEqual(renamedProject.scope, project.scope)
        let reopened = try WorkspaceCatalog(container: root)
        let workspaces = try await reopened.workspaces()
        let projects = try await reopened.projects(in: workspace.id)
        XCTAssertEqual(workspaces, [renamed]); XCTAssertEqual(projects, [renamedProject])
        let json = try Data(contentsOf: root.appendingPathComponent("\(workspace.id)/workspace.json"))
        XCTAssertTrue(String(decoding: json, as: UTF8.self).contains("\n"))
        let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(files, [workspace.id.rawValue])
    }

    @MainActor
    func testDuplicateNamesAreNormalizedAndScoped() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let first = try await catalog.createWorkspace(name: "Café")
        let second = try await catalog.createWorkspace(name: "Second")
        for name in ["CAFÉ", " Cafe\u{301} "] {
            do { _ = try await catalog.createWorkspace(name: name); XCTFail("Duplicate accepted") }
            catch { XCTAssertEqual(error as? CatalogError, .duplicateName) }
        }
        let project = try await catalog.createProject(in: first.id, name: "Website")
        _ = try await catalog.createProject(in: second.id, name: "Website")
        do { _ = try await catalog.createProject(in: first.id, name: " website "); XCTFail("Duplicate accepted") }
        catch { XCTAssertEqual(error as? CatalogError, .duplicateName) }
        let other = try await catalog.createProject(in: first.id, name: "Other")
        do { _ = try await catalog.renameProject(other.scope, name: project.name); XCTFail("Duplicate rename") }
        catch { XCTAssertEqual(error as? CatalogError, .duplicateName) }
        do { _ = try await catalog.renameWorkspace(second.id, name: first.name); XCTFail("Duplicate rename") }
        catch { XCTAssertEqual(error as? CatalogError, .duplicateName) }
    }

    @MainActor
    func testInvalidNamesLeaveNoPartialWorkspace() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        for name in ["", " \n ", "a/b", "a\\b", "a\u{0}b", "a\nb", String(repeating: "x", count: 101)] {
            do { _ = try await catalog.createWorkspace(name: name); XCTFail("Invalid name accepted") }
            catch { XCTAssertEqual(error as? CatalogError, .invalidName) }
        }
        let records = try await catalog.workspaces(); XCTAssertTrue(records.isEmpty)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty)
    }

    @MainActor
    func testProjectLookupAndRenameRejectForeignScope() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let first = try await catalog.createWorkspace(name: "First")
        let second = try await catalog.createWorkspace(name: "Second")
        let project = try await catalog.createProject(in: first.id, name: "Private")
        let wrong = ProjectScope(workspaceID: second.id, projectID: project.id)
        do { _ = try await catalog.project(wrong); XCTFail("Foreign lookup") }
        catch { XCTAssertEqual(error as? ScopedFileError, .notFound) }
        do { _ = try await catalog.renameProject(wrong, name: "Changed"); XCTFail("Foreign rename") }
        catch { XCTAssertEqual(error as? ScopedFileError, .notFound) }
        let original = try await catalog.project(project.scope); XCTAssertEqual(original.name, "Private")
        // Even a physically copied project cannot claim membership in its new parent.
        let source = root.appendingPathComponent("\(first.id)/Projects/\(project.id)")
        let target = root.appendingPathComponent("\(second.id)/Projects/\(project.id)")
        try FileManager.default.copyItem(at: source, to: target)
        do { _ = try await catalog.projects(in: second.id); XCTFail("Forged membership accepted") }
        catch { XCTAssertEqual(error as? CatalogError, .scopeMismatch) }
    }

    @MainActor
    func testMalformedUnsupportedAndMismatchedWorkspaceArePreserved() async throws {
        for mutation in ["malformed", "version", "identity", "name"] {
            let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
            let catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Fixture")
            let url = root.appendingPathComponent("\(workspace.id)/workspace.json")
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            switch mutation {
            case "version": object["schemaVersion"] = 99
            case "identity": object["id"] = WorkspaceID().rawValue
            case "name": object["name"] = "../invalid/name"
            default: break
            }
            let data = mutation == "malformed" ? Data("{broken".utf8) : try JSONSerialization.data(withJSONObject: object)
            try data.write(to: url)
            do { _ = try await catalog.workspaces(); XCTFail("Invalid configuration accepted: \(mutation)") }
            catch {
                let expected: CatalogError = mutation == "version" ? .unsupportedVersion : mutation == "identity" ? .scopeMismatch : .invalidConfiguration
                XCTAssertEqual(error as? CatalogError, expected)
            }
            XCTAssertEqual(try Data(contentsOf: url), data)
        }
    }

    @MainActor
    func testCatalogRejectsLinkedProjectDirectoryAndConfigurationWrites() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let first = try await catalog.createWorkspace(name: "First")
        let second = try await catalog.createWorkspace(name: "Second")
        let projects = root.appendingPathComponent("\(first.id)/Projects")
        try FileManager.default.removeItem(at: projects)
        try FileManager.default.createSymbolicLink(at: projects, withDestinationURL: root.appendingPathComponent("\(second.id)/Projects"))
        do { _ = try await catalog.createProject(in: first.id, name: "Escape"); XCTFail("Symlink followed") }
        catch { XCTAssertEqual(error as? ScopedFileError, .unsafeFile) }
        let config = root.appendingPathComponent("\(first.id)/workspace.json")
        let target = root.appendingPathComponent("\(second.id)/workspace.json")
        let before = try Data(contentsOf: target)
        try FileManager.default.removeItem(at: config)
        try FileManager.default.createSymbolicLink(at: config, withDestinationURL: target)
        do { _ = try await catalog.renameWorkspace(first.id, name: "Escape"); XCTFail("Symlink overwritten") }
        catch { XCTAssertEqual(error as? ScopedFileError, .unsafeFile) }
        XCTAssertEqual(try Data(contentsOf: target), before)
    }

    @MainActor
    func testCancellationDoesNotCreateConfiguration() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await catalog.createWorkspace(name: "Cancelled")
        }
        do { _ = try await task.value; XCTFail("Cancelled creation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let records = try await catalog.workspaces(); XCTAssertTrue(records.isEmpty)
    }

    @MainActor
    func testConcurrentCatalogsDoNotCommitDuplicateNames() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let first = try WorkspaceCatalog(container: root), second = try WorkspaceCatalog(container: root)
        let count = await withTaskGroup(of: Bool.self, returning: Int.self) { group in
            for catalog in [first, second] {
                group.addTask { (try? await catalog.createWorkspace(name: "Same")) != nil }
            }
            var count = 0
            for await success in group { if success { count += 1 } }
            return count
        }
        XCTAssertEqual(count, 1)
        let records = try await first.workspaces(); XCTAssertEqual(records.count, 1)
        _ = try await second.createWorkspace(name: "After lock released")
    }

    @MainActor
    func testInterruptedStagingIsNotPresentedAsCommittedData() async throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".new-interrupted"), withIntermediateDirectories: false)
        let catalog = try WorkspaceCatalog(container: root)
        let records = try await catalog.workspaces(); XCTAssertTrue(records.isEmpty)
        _ = try await catalog.createWorkspace(name: "Committed")
        let after = try await catalog.workspaces(); XCTAssertEqual(after.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".new-interrupted").path))
    }

    @MainActor
    func testAtomicWritesNeverFollowOrReplaceExistingFileWithoutIntent() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let directory = try ConfigurationDirectory(trustedContainer: root)
        try directory.write(Data("original".utf8), to: "file.json")
        XCTAssertThrowsError(try directory.write(Data("collision".utf8), to: "file.json"))
        XCTAssertEqual(try directory.read("file.json", maximumBytes: 100), Data("original".utf8))
        try directory.write(Data("replacement".utf8), to: "file.json", replacing: true)
        XCTAssertEqual(try directory.read("file.json", maximumBytes: 100), Data("replacement".utf8))
        XCTAssertEqual(try directory.names(), ["file.json"])
    }
}
