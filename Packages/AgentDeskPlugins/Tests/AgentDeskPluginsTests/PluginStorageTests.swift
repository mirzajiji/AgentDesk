import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class PluginStorageTests: XCTestCase {
    @MainActor
    func testListingPagesPublishedHeadsAndFiltersEnvironment() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "Connections")
        let store = try await catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: project.scope)
        let empty = try await store.list(in: project.scope)
        XCTAssertTrue(empty.records.isEmpty); XCTAssertNil(empty.nextID)
        let environment = EnvironmentID(), other = EnvironmentID()
        var expected: [UUID] = []
        for index in 0..<5 {
            let value = try JiraConnectionConfiguration(scope: project.scope, environmentID: index == 2 ? other : environment,
                instance: XCTUnwrap(URL(string: "https://synthetic.atlassian.net")))
            _ = try await store.save(value, in: project.scope, expectedRevision: nil)
            if index != 2 { expected.append(value.id) }
        }
        let first = try await store.list(in: project.scope, environmentID: environment, limit: 2)
        XCTAssertEqual(first.records.count, 2)
        let cursor = try XCTUnwrap(first.nextID)
        let reopened = try await catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: project.scope)
        let second = try await reopened.list(in: project.scope, environmentID: environment, after: cursor, limit: 2)
        XCTAssertNil(second.nextID)
        XCTAssertEqual((first.records + second.records).map { $0.configuration.id }, expected.sorted { $0.uuidString < $1.uuidString })
        do { _ = try await store.list(in: .init(workspaceID: workspace.id, projectID: ProjectID())); XCTFail("Foreign list accepted") }
        catch { XCTAssertEqual(error as? PluginStorageError, .scopeMismatch) }
        do { _ = try await store.list(in: project.scope, limit: 0); XCTFail("Invalid page accepted") }
        catch { XCTAssertEqual(error as? PluginStorageError, .invalidRecord) }
    }

    @MainActor
    func testReopenHistoryAndStaleEdits() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "First")
        let store = try await catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: project.scope)
        let first = try JiraConnectionConfiguration(scope: project.scope, environmentID: EnvironmentID(),
            instance: XCTUnwrap(URL(string: "https://jira.example.test")))
        let saved = try await store.save(first, in: project.scope, expectedRevision: nil)
        XCTAssertEqual(saved.revision, 1)
        let second = try JiraConnectionConfiguration(id: first.id, scope: first.scope, environmentID: first.environmentID,
            instance: first.instance, enabled: true)
        _ = try await store.save(second, in: project.scope, expectedRevision: 1)
        do {
            _ = try await store.save(first, in: project.scope, expectedRevision: 1)
            XCTFail("Stale editor overwrote newer configuration")
        } catch { XCTAssertEqual(error as? PluginStorageError, .staleRevision) }
        let reopenedCatalog = try WorkspaceCatalog(container: root)
        let reopened = try await reopenedCatalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: project.scope)
        let current = try await reopened.read(id: first.id, in: project.scope)
        let historical = try await reopened.read(id: first.id, in: project.scope, revision: 1)
        XCTAssertEqual(current?.revision, 2)
        XCTAssertEqual(current?.configuration, second)
        XCTAssertEqual(historical?.configuration, first)
    }

    @MainActor
    func testOrphanRevisionIsPreservedAndSymlinkReadIsRejected() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "First")
        let store = try await catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: project.scope)
        let value = try JiraConnectionConfiguration(scope: project.scope, environmentID: EnvironmentID(),
            instance: XCTUnwrap(URL(string: "https://jira.example.test")))
        _ = try await store.save(value, in: project.scope, expectedRevision: nil)
        let folder = root.appendingPathComponent("\(workspace.id)/Projects/\(project.id)/Plugins/\(value.id.uuidString.lowercased())")
        let first = folder.appendingPathComponent("Versions/1")
        let orphan = folder.appendingPathComponent("Versions/2")
        let original = try Data(contentsOf: first)
        // Simulate publication of a revision whose current-pointer update never completed.
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        document["revision"] = 2
        let orphanData = try JSONSerialization.data(withJSONObject: document)
        try orphanData.write(to: orphan)
        let current = try await store.read(id: value.id, in: project.scope)
        XCTAssertEqual(current?.revision, 1)
        let next = try await store.save(value, in: project.scope, expectedRevision: 1)
        XCTAssertEqual(next.revision, 3)
        XCTAssertEqual(try Data(contentsOf: first), original)
        XCTAssertEqual(try Data(contentsOf: orphan), orphanData)
        let third = folder.appendingPathComponent("Versions/3")
        try FileManager.default.removeItem(at: third)
        try FileManager.default.createSymbolicLink(at: third, withDestinationURL: first)
        do {
            _ = try await store.read(id: value.id, in: project.scope)
            XCTFail("Symlink revision followed")
        } catch { XCTAssertEqual(error as? ScopedFileError, .unsafeFile) }
    }

    @MainActor
    func testForgedCurrentPointerIsRejectedAndPreserved() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "First")
        let store = try await catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: project.scope)
        let value = try JiraConnectionConfiguration(scope: project.scope, environmentID: EnvironmentID(),
            instance: XCTUnwrap(URL(string: "https://jira.example.test")))
        _ = try await store.save(value, in: project.scope, expectedRevision: nil)
        let pointer = root.appendingPathComponent("\(workspace.id)/Projects/\(project.id)/Plugins/\(value.id.uuidString.lowercased())/current.json")
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: pointer)) as? [String: Any])
        document["id"] = UUID().uuidString
        let forged = try JSONSerialization.data(withJSONObject: document)
        try forged.write(to: pointer)
        do {
            _ = try await store.read(id: value.id, in: project.scope)
            XCTFail("Forged pointer accepted")
        } catch { XCTAssertEqual(error as? PluginStorageError, .invalidRecord) }
        do {
            _ = try await store.save(value, in: project.scope, expectedRevision: 1)
            XCTFail("Invalid pointer overwritten")
        } catch { XCTAssertEqual(error as? PluginStorageError, .invalidRecord) }
        XCTAssertEqual(try Data(contentsOf: pointer), forged)
    }

    @MainActor
    func testForeignReadAndSaveDoNotCreateFiles() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let first = try await catalog.createProject(in: workspace.id, name: "First")
        let second = try await catalog.createProject(in: workspace.id, name: "Second")
        let store = try await catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: first.scope)
        let foreign = try JiraConnectionConfiguration(scope: second.scope, environmentID: EnvironmentID(),
            instance: XCTUnwrap(URL(string: "https://jira.example.test")))
        do {
            _ = try await store.save(foreign, in: first.scope, expectedRevision: nil)
            XCTFail("Foreign document accepted")
        } catch { XCTAssertEqual(error as? PluginStorageError, .scopeMismatch) }
        do {
            _ = try await store.read(id: foreign.id, in: second.scope)
            XCTFail("Foreign read accepted")
        } catch { XCTAssertEqual(error as? PluginStorageError, .scopeMismatch) }
        let path = root.appendingPathComponent("\(workspace.id)/Projects/\(first.id)/Plugins")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
    }
}
