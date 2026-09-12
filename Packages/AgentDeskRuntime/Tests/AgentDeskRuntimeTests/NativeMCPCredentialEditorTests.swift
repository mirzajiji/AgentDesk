#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor final class NativeMCPCredentialEditorTests: XCTestCase {
    func testReplacementPreservesHistoryAndNeverWritesValuesToConfiguration() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let first = try await f.editor.set(connectionID: f.id, expectedRevision: 1, variable: "TOKEN", value: SecretValue(Data("synthetic-first-secret".utf8)))
        let second = try await f.editor.set(connectionID: f.id, expectedRevision: 2, variable: "TOKEN", value: SecretValue(Data("synthetic-next-secret".utf8)))
        XCTAssertNotEqual(first.configuration.secretEnvironment["TOKEN"], second.configuration.secretEnvironment["TOKEN"])
        let history = try await f.store.read(id: f.id, in: f.scope, revision: 2)
        XCTAssertEqual(history?.configuration, first.configuration)
        let bytes = try JSONEncoder().encode(second)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("synthetic-next-secret"))
        let count = await f.secrets.count; XCTAssertEqual(count, 2)
        do { _ = try await f.editor.set(connectionID: f.id, expectedRevision: 1, variable: "TOKEN", value: SecretValue(Data("unused".utf8))); XCTFail("Accepted stale edit") }
        catch { XCTAssertEqual(error as? MCPStorageError, .staleRevision) }
        let finalCount = await f.secrets.count; XCTAssertEqual(finalCount, 2)
    }
    func testInvalidInputIsRejectedBeforeSecretWrite() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        for (key, bytes) in [("1INVALID", Data("value".utf8)), ("TOKEN", Data([0xff])), ("TOKEN", Data([65, 0, 66]))] {
            do { _ = try await f.editor.set(connectionID: f.id, expectedRevision: 1, variable: key, value: SecretValue(bytes)); XCTFail("Accepted invalid input") }
            catch { }
        }
        let count = await f.secrets.count; XCTAssertEqual(count, 0)
    }
    func testConcurrentConfigurationChangeRollsBackNewSecret() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        await f.secrets.onSet {
            let current = try await f.store.read(id: f.id, in: f.scope)!
            _ = try await f.store.save(current.configuration, in: f.scope, expectedRevision: 1)
        }
        do { _ = try await f.editor.set(connectionID: f.id, expectedRevision: 1, variable: "TOKEN", value: SecretValue(Data("synthetic".utf8))); XCTFail("Accepted concurrent change") }
        catch { XCTAssertEqual(error as? MCPStorageError, .staleRevision) }
        let count = await f.secrets.count; XCTAssertEqual(count, 0)
    }
    func testCancellationStillRollsBackUsingUncancelledCleanup() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        await f.secrets.onSet { withUnsafeCurrentTask { $0?.cancel() } }
        let operation = Task { try await f.editor.set(connectionID: f.id, expectedRevision: 1, variable: "TOKEN", value: SecretValue(Data("synthetic".utf8))) }
        do { _ = try await operation.value; XCTFail("Cancelled edit succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await f.secrets.count; XCTAssertEqual(count, 0)
        let current = try await f.store.read(id: f.id, in: f.scope)
        XCTAssertEqual(current?.revision, 1)
    }
    func testPartialWriteAndFailedRollbackReturnOnlyRecoveryReference() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        await f.secrets.onSet { throw SecretStoreError.invalidResult }
        await f.secrets.failCleanup()
        do { _ = try await f.editor.set(connectionID: f.id, expectedRevision: 1, variable: "TOKEN", value: SecretValue(Data("synthetic-private-value".utf8))); XCTFail("Partial write succeeded") }
        catch let MCPCredentialEditError.cleanupRequired(reference) {
            XCTAssertEqual(reference.scope, f.secrets.scope)
            let exists = try await f.secrets.exists(reference); XCTAssertTrue(exists)
            XCTAssertFalse(String(reflecting: MCPCredentialEditError.cleanupRequired(reference)).contains("synthetic-private-value"))
        }
        let current = try await f.store.read(id: f.id, in: f.scope)
        XCTAssertEqual(current?.revision, 1); XCTAssertTrue(current?.configuration.secretEnvironment.isEmpty == true)
    }
    func testForeignSecretStoreIsRejected() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let foreign = EditorSecrets(scope: try SecretScope(workspaceID: f.scope.workspaceID, projectID: ProjectID(), environmentID: EnvironmentID()))
        do {
            _ = try NativeMCPCredentialEditor(configurations: f.store, secrets: foreign, scope: f.scope, environmentID: EnvironmentID())
            XCTFail("Accepted foreign secret store")
        } catch { XCTAssertEqual(error as? SecretStoreError, .scopeMismatch) }
    }
    private struct Fixture: Sendable {
        let root: URL, scope: ProjectScope, id: UUID
        let store: ProjectMCPConfigurationStore<MCPStdioConfiguration>
        let secrets: EditorSecrets
        let editor: NativeMCPCredentialEditor
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let catalog = try WorkspaceCatalog(container: root), workspace = try await catalog.createWorkspace(name: "Synthetic")
            let project = try await catalog.createProject(in: workspace.id, name: "MCP"), environment = EnvironmentID()
            let store = try await catalog.mcpConfigurationStore(for: MCPStdioConfiguration.self, in: project.scope)
            let value = try MCPStdioConfiguration(scope: project.scope, environmentID: environment, name: "Synthetic", executable: "/usr/bin/true", workingDirectory: nil, directoryBase: .registeredRepository)
            _ = try await store.save(value, in: project.scope, expectedRevision: nil)
            let secrets = EditorSecrets(scope: try SecretScope(workspaceID: workspace.id, projectID: project.id, environmentID: environment))
            return Self(root: root, scope: project.scope, id: value.id, store: store, secrets: secrets,
                editor: try NativeMCPCredentialEditor(configurations: store, secrets: secrets, scope: project.scope, environmentID: environment))
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}
private actor EditorSecrets: SecretStore {
    nonisolated let scope: SecretScope
    var values: [SecretReference: SecretValue] = [:]
    var afterSet: (@Sendable () async throws -> Void)?
    var count: Int { values.count }
    var cleanupFails = false
    func failCleanup() { cleanupFails = true }
    init(scope: SecretScope) { self.scope = scope }
    func onSet(_ action: @escaping @Sendable () async throws -> Void) { afterSet = action }
    func set(_ value: SecretValue, for reference: SecretReference) async throws { values[reference] = value; try await afterSet?() }
    func get(_ reference: SecretReference) async throws -> SecretValue? { values[reference] }
    func delete(_ reference: SecretReference) async throws {
        try Task.checkCancellation()
        if cleanupFails { throw SecretStoreError.invalidResult }
        values[reference] = nil
    }
    func exists(_ reference: SecretReference) async throws -> Bool { values[reference] != nil }
}
#endif
