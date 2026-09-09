import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest

/// Runs in the signed native app host, using only synthetic, random-scope Keychain items.
final class KeychainIntegrationTests: XCTestCase {
    @MainActor
    func testNativeKeychainRoundTripUpdateReopenAndDeletion() async throws {
        let scope = try SecretScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let store = KeychainSecretStore(scope: scope)
        let reference = SecretReference(scope: scope)
        do {
            let missing = try await store.get(reference); XCTAssertNil(missing)
            let absent = try await store.exists(reference); XCTAssertFalse(absent)
            try await store.set(SecretValue(Data("synthetic-first".utf8)), for: reference)
            try await store.set(SecretValue(Data("synthetic-updated".utf8)), for: reference)
            let reopened = KeychainSecretStore(scope: scope)
            let present = try await reopened.exists(reference); XCTAssertTrue(present)
            let value = try await reopened.get(reference)
            XCTAssertEqual(value?.withBytes { $0 }, Data("synthetic-updated".utf8))
            try await reopened.delete(reference)
            try await reopened.delete(reference)
            let deleted = try await store.exists(reference); XCTAssertFalse(deleted)
        } catch {
            try? await store.delete(reference)
            throw error
        }
    }

    @MainActor
    func testNativeKeychainSameIdentityInDifferentScopesStaysSeparate() async throws {
        let workspace = WorkspaceID(), project = ProjectID(), id = UUID()
        let firstScope = try SecretScope(workspaceID: workspace, projectID: project, environmentID: EnvironmentID())
        let secondScope = try SecretScope(workspaceID: workspace, projectID: project, environmentID: EnvironmentID())
        let first = KeychainSecretStore(scope: firstScope), second = KeychainSecretStore(scope: secondScope)
        let firstRef = SecretReference(scope: firstScope, id: id), secondRef = SecretReference(scope: secondScope, id: id)
        do {
            try await first.set(SecretValue(Data([1])), for: firstRef)
            try await second.set(SecretValue(Data([2])), for: secondRef)
            let firstValue = try await first.get(firstRef), secondValue = try await second.get(secondRef)
            XCTAssertEqual(firstValue?.withBytes { $0 }, Data([1]))
            XCTAssertEqual(secondValue?.withBytes { $0 }, Data([2]))
            do { _ = try await first.get(secondRef); XCTFail("Cross-environment access") }
            catch { XCTAssertEqual(error as? SecretStoreError, .scopeMismatch) }
            try await first.delete(firstRef)
            let stillExists = try await second.exists(secondRef); XCTAssertTrue(stillExists)
            try await second.delete(secondRef)
        } catch {
            try? await first.delete(firstRef)
            try? await second.delete(secondRef)
            throw error
        }
    }
}
