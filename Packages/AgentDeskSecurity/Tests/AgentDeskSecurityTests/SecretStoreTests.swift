import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskSecurity

final class SecretStoreTests: XCTestCase {
    func testReferenceRoundTripAndDistinctScopeAccounts() throws {
        let workspace = WorkspaceID(), project = ProjectID()
        let scope = try SecretScope(workspaceID: workspace, projectID: project, environmentID: EnvironmentID())
        let reference = SecretReference(scope: scope)
        XCTAssertEqual(try JSONDecoder().decode(SecretReference.self, from: JSONEncoder().encode(reference)), reference)
        let other = SecretReference(scope: try SecretScope(workspaceID: workspace, projectID: project), id: reference.id)
        XCTAssertNotEqual(reference.account, other.account)
        let foreign = SecretReference(scope: try SecretScope(workspaceID: WorkspaceID(), projectID: project), id: reference.id)
        XCTAssertNotEqual(reference.account, foreign.account)
    }

    func testEnvironmentCannotDecodeWithoutProject() throws {
        XCTAssertThrowsError(try SecretScope(workspaceID: WorkspaceID(), environmentID: EnvironmentID()))
        let data = try JSONSerialization.data(withJSONObject: ["workspaceID": WorkspaceID().rawValue,
                                                              "environmentID": EnvironmentID().rawValue])
        XCTAssertThrowsError(try JSONDecoder().decode(SecretScope.self, from: data))
    }

    func testSecretDiagnosticRepresentationsHideBytesAndRejectInvalidValues() throws {
        let value = try SecretValue(Data("synthetic-sensitive-value".utf8))
        XCTAssertEqual(String(describing: value), "<redacted secret>")
        XCTAssertEqual(String(reflecting: value), "<redacted secret>")
        var diagnostic = ""
        dump(value, to: &diagnostic)
        XCTAssertFalse(diagnostic.contains("synthetic-sensitive-value"))
        XCTAssertTrue(diagnostic.contains("redacted"))
        XCTAssertEqual(value.withBytes { $0.count }, 25)
        XCTAssertThrowsError(try SecretValue(Data()))
        XCTAssertThrowsError(try SecretValue(Data(repeating: 1, count: 65_537)))
    }

    @MainActor
    func testScopeIsCheckedBeforeEveryBackendOperation() async throws {
        let scope = try SecretScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let store = KeychainSecretStore(scope: scope, backend: FailedBackend())
        let reference = SecretReference(scope: try SecretScope(workspaceID: scope.workspaceID, projectID: ProjectID()))
        do { try await store.set(SecretValue(Data([1])), for: reference); XCTFail("Cross-scope set") }
        catch { XCTAssertEqual(error as? SecretStoreError, .scopeMismatch) }
        do { _ = try await store.get(reference); XCTFail("Cross-scope get") }
        catch { XCTAssertEqual(error as? SecretStoreError, .scopeMismatch) }
        do { try await store.delete(reference); XCTFail("Cross-scope delete") }
        catch { XCTAssertEqual(error as? SecretStoreError, .scopeMismatch) }
        do { _ = try await store.exists(reference); XCTFail("Cross-scope exists") }
        catch { XCTAssertEqual(error as? SecretStoreError, .scopeMismatch) }
    }

    @MainActor
    func testKeychainFailuresRemainErrorsRatherThanMissingItems() async throws {
        let scope = try SecretScope(workspaceID: WorkspaceID())
        let store = KeychainSecretStore(scope: scope, backend: FailedBackend())
        let reference = SecretReference(scope: scope)
        do { _ = try await store.get(reference); XCTFail("Failure hidden") }
        catch { XCTAssertEqual(error as? SecretStoreError, .keychain(-25308)) }
        do { _ = try await store.exists(reference); XCTFail("Failure hidden") }
        catch { XCTAssertEqual(error as? SecretStoreError, .keychain(-25308)) }
    }

    @MainActor
    func testCancellationPreventsBackendAccess() async throws {
        let scope = try SecretScope(workspaceID: WorkspaceID())
        let store = KeychainSecretStore(scope: scope, backend: FailedBackend())
        let reference = SecretReference(scope: scope)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.get(reference)
        }
        do { _ = try await task.value; XCTFail("Cancelled access") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    @MainActor
    func testInjectableStoreContractRoundTripUpdateMissingAndDelete() async throws {
        let scope = try SecretScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let store: any SecretStore = MemorySecretStore(scope: scope)
        let reference = SecretReference(scope: scope)
        let missing = try await store.get(reference); XCTAssertNil(missing)
        try await store.set(SecretValue(Data([1, 2, 3])), for: reference)
        try await store.set(SecretValue(Data([4, 5])), for: reference)
        let present = try await store.exists(reference); XCTAssertTrue(present)
        let stored = try await store.get(reference); XCTAssertEqual(stored?.withBytes { $0 }, Data([4, 5]))
        try await store.delete(reference)
        try await store.delete(reference)
        let absent = try await store.exists(reference); XCTAssertFalse(absent)
    }
}

private struct FailedBackend: KeychainBackend {
    func set(_ data: Data, service: String, account: String) throws { throw SecretStoreError.keychain(-25308) }
    func get(service: String, account: String) throws -> Data? { throw SecretStoreError.keychain(-25308) }
    func delete(service: String, account: String) throws { throw SecretStoreError.keychain(-25308) }
    func exists(service: String, account: String) throws -> Bool { throw SecretStoreError.keychain(-25308) }
}

/// Test-only dependency; production never silently falls back from Keychain to memory or files.
private actor MemorySecretStore: SecretStore {
    nonisolated let scope: SecretScope
    private var values: [SecretReference: SecretValue] = [:]
    init(scope: SecretScope) { self.scope = scope }
    func set(_ value: SecretValue, for reference: SecretReference) throws { try validate(reference); values[reference] = value }
    func get(_ reference: SecretReference) throws -> SecretValue? { try validate(reference); return values[reference] }
    func delete(_ reference: SecretReference) throws { try validate(reference); values.removeValue(forKey: reference) }
    func exists(_ reference: SecretReference) throws -> Bool { try validate(reference); return values[reference] != nil }
    private func validate(_ reference: SecretReference) throws {
        try Task.checkCancellation()
        guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }
    }
}
