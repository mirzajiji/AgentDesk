import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraOAuthLoginRaceTests: XCTestCase {
    @MainActor func testRefreshRejectsCompetingOperationsAndCannotOutliveLogout() async throws {
        let initial = expectation(description: "Initial grant save")
        let (login, broker, store) = try fixture(entered: initial, failAfterWrite: false)
        let signingIn = Task { try await login.signIn { _ in } }
        await fulfillment(of: [initial], timeout: 5)
        await store.releaseSave()
        _ = try await signingIn.value

        let replacement = expectation(description: "Replacement grant save")
        await store.expectSave(replacement)
        let refreshing = Task { try await login.refresh() }
        await fulfillment(of: [replacement], timeout: 5)
        do { _ = try await login.refresh(); XCTFail("Concurrent refresh accepted") }
        catch { XCTAssertEqual(error as? JiraServiceError, .unavailable) }
        do { _ = try await login.signIn { _ in XCTFail("Competing browser opened") }; XCTFail("Concurrent login accepted") }
        catch { XCTAssertEqual(error as? JiraServiceError, .unavailable) }
        refreshing.cancel()
        let loggingOut = Task { try await login.logout() }
        await store.releaseSave()
        do { _ = try await refreshing.value; XCTFail("Cancelled refresh succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await loggingOut.value
        let remains = await store.hasValue
        XCTAssertFalse(remains)
        await broker.close()
    }

    @MainActor func testCancelledSaveCannotRecreateGrantAfterLogout() async throws {
        let entered = expectation(description: "Credential save entered")
        let (login, broker, store) = try fixture(entered: entered, failAfterWrite: false)
        let signingIn = Task { try await login.signIn { _ in } }
        await fulfillment(of: [entered], timeout: 5)
        signingIn.cancel()
        let loggingOut = Task { try await login.logout() }
        await store.releaseSave()
        do { _ = try await signingIn.value; XCTFail("Cancelled login succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        try await loggingOut.value
        let remains = await store.hasValue
        XCTAssertFalse(remains)
        await broker.close()
    }

    @MainActor func testWriteThenFailureDeletesAmbiguousGrant() async throws {
        let entered = expectation(description: "Credential save entered")
        let (login, broker, store) = try fixture(entered: entered, failAfterWrite: true)
        let signingIn = Task { try await login.signIn { _ in } }
        await fulfillment(of: [entered], timeout: 5)
        await store.releaseSave()
        do { _ = try await signingIn.value; XCTFail("Failed save succeeded") }
        catch { XCTAssertEqual(error as? SecretStoreError, .invalidResult) }
        let remains = await store.hasValue
        XCTAssertFalse(remains, "A store can write before reporting failure")
        await broker.close()
    }

    @MainActor func testCleanupFailureIsReportedAndLogoutCanRetry() async throws {
        let entered = expectation(description: "Credential save entered")
        let (login, broker, store) = try fixture(entered: entered, failAfterWrite: true)
        await store.setDeletionFailure(true)
        let signingIn = Task { try await login.signIn { _ in } }
        await fulfillment(of: [entered], timeout: 5)
        await store.releaseSave()
        do { _ = try await signingIn.value; XCTFail("Failed cleanup succeeded") }
        catch { XCTAssertEqual(error as? JiraOAuthError, .credentialCleanupFailed) }
        let retained = await store.hasValue
        XCTAssertTrue(retained)
        do { try await login.logout(); XCTFail("Failed deletion reported logout success") }
        catch { XCTAssertEqual(error as? SecretStoreError, .keychain(-1)) }
        await store.setDeletionFailure(false)
        try await login.logout()
        let remains = await store.hasValue
        XCTAssertFalse(remains)
        await broker.close()
    }

    private func fixture(entered: XCTestExpectation, failAfterWrite: Bool) throws
        -> (JiraOAuthLogin, JiraOAuthBrokerClient, PausingLoginSecrets) {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, credential: SecretReference(scope: secretScope), enabled: true)
        let store = PausingLoginSecrets(scope: secretScope, entered: entered, failAfterWrite: failAfterWrite)
        let broker = try JiraOAuthBrokerClient(origin: URL(string: "https://broker.example")!, clientID: "synthetic-client",
            callback: URL(string: "https://broker.example/callback")!, protocolClasses: [NativeBrokerProtocol.self])
        let adapter = JiraCloudAdapter(store: store, now: { Date() }, makeTransport: {
            try JiraHTTPTransport(origin: $0, protocolClasses: [AdapterProtocol.self])
        })
        return (try JiraOAuthLogin(configuration: config, broker: broker, adapter: adapter, store: store), broker, store)
    }
}

private actor PausingLoginSecrets: SecretStore {
    nonisolated let scope: SecretScope
    private var entered: XCTestExpectation
    private let failAfterWrite: Bool
    private var continuation: CheckedContinuation<Void, Never>?
    private var value: SecretValue?
    private var deletionFails = false
    init(scope: SecretScope, entered: XCTestExpectation, failAfterWrite: Bool) {
        self.scope = scope; self.entered = entered; self.failAfterWrite = failAfterWrite
    }
    var hasValue: Bool { value != nil }
    func set(_ value: SecretValue, for reference: SecretReference) async throws {
        guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            entered.fulfill()
        }
        // Simulate a non-cancellable in-flight Keychain write.
        self.value = value
        if failAfterWrite { throw SecretStoreError.invalidResult }
    }
    func expectSave(_ expectation: XCTestExpectation) { entered = expectation }
    func releaseSave() { continuation?.resume(); continuation = nil }
    func get(_ reference: SecretReference) -> SecretValue? { value }
    func setDeletionFailure(_ fails: Bool) { deletionFails = fails }
    func delete(_ reference: SecretReference) throws {
        if deletionFails { throw SecretStoreError.keychain(-1) }
        value = nil
    }
    func exists(_ reference: SecretReference) -> Bool { value != nil }
}
