#if os(macOS)
import AgentDeskCore
import AgentDeskPlugins
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDesk

@MainActor final class NativeJiraSignInTests: XCTestCase {
    func testRegistrationRejectsWorkspaceStyleOverridesAndRequestsReadOnly() throws {
        let fields = ["brokerOrigin": "https://broker.example", "clientID": "synthetic", "callback": "https://broker.example/callback"]
        XCTAssertEqual(try NativeJiraRegistration.decode(fields).access, .readOnly)
        var modified = fields; modified["clientSecret"] = "synthetic"
        XCTAssertThrowsError(try NativeJiraRegistration.decode(modified))
        modified = fields; modified["callback"] = "https://foreign.example/callback"
        XCTAssertThrowsError(try NativeJiraRegistration.decode(modified))
        XCTAssertThrowsError(try NativeJiraRegistration.decode(["clientID": "synthetic"]))
    }

    func testScopedReferenceReservationSuccessAndChangedConfiguration() async throws {
        for mode in 0...2 {
            let change = mode == 1
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic")
            let project = try await catalog.createProject(in: workspace.id, name: "Sign in")
            let environment = ProjectEnvironment(scope: project.scope, name: "Development")
            let store = try await catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: project.scope)
            let fake = FakeNativeJiraLogin {
                if mode == 2 { try await Task.sleep(for: .seconds(60)) }
                if change, let current = try await store.list(in: project.scope).records.first {
                    let value = current.configuration
                    let disabled = try JiraConnectionConfiguration(id: value.id, scope: value.scope, environmentID: value.environmentID,
                        instance: value.instance, credential: value.credential, enabled: false)
                    _ = try await store.save(disabled, in: project.scope, expectedRevision: current.revision)
                }
            }
            let model = ProjectJiraConnectionsModel(project: project, makeLogin: { configuration, _ in
                XCTAssertEqual(configuration.credential?.scope.workspaceID, project.workspaceID)
                XCTAssertEqual(configuration.credential?.scope.projectID, project.id)
                XCTAssertEqual(configuration.credential?.scope.environmentID, environment.id)
                return fake
            }, open: { NativeJiraConfigurationServices(store: store, environments: [environment]) })
            try await model.save(instance: "https://synthetic.atlassian.net", environment: environment.id, enabled: true, existing: nil)
            let first = try XCTUnwrap(model.records.first)
            let registration = try NativeJiraRegistration.decode(["brokerOrigin": "https://broker.example", "clientID": "synthetic", "callback": "https://broker.example/callback"])
            model.signIn(first, registration: registration) { _ in XCTFail("Fake login opened real browser") }
            let deadline = ContinuousClock.now.advanced(by: .seconds(10))
            if mode == 2 {
                while !(await fake.started), ContinuousClock.now < deadline { await Task.yield() }
                model.cancelSignIn()
            }
            while model.busy, ContinuousClock.now < deadline { await Task.yield() }
            XCTAssertFalse(model.busy, "Sign-in did not terminate")
            XCTAssertEqual(model.error == nil, mode == 0)
            XCTAssertEqual(model.authenticationMessage != nil, mode == 0)
            XCTAssertNotNil(model.records.first?.configuration.credential)
            let closed = await fake.closed
            XCTAssertTrue(closed)
            model.close()
        }
    }

    func testLogoutDeletesOnlyCurrentScopedGrantAndReportsFailure() async throws {
        for fails in [false, true] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic")
            let project = try await catalog.createProject(in: workspace.id, name: "Logout")
            let environment = EnvironmentID()
            let scope = try SecretScope(workspaceID: workspace.id, projectID: project.id, environmentID: environment)
            let reference = SecretReference(scope: scope)
            let store = try await catalog.pluginConfigurationStore(for: JiraConnectionConfiguration.self, in: project.scope)
            let value = try JiraConnectionConfiguration(scope: project.scope, environmentID: environment,
                instance: URL(string: "https://synthetic.atlassian.net")!, credential: reference, enabled: false)
            let first = try await store.save(value, in: project.scope, expectedRevision: nil)
            let calls = Mutex<[SecretReference]>([])
            let model = ProjectJiraConnectionsModel(project: project, removeGrant: { requested in
                calls.withLock { $0.append(requested) }
                if fails { throw SecretStoreError.invalidResult }
            }, open: { NativeJiraConfigurationServices(store: store, environments: []) })
            // Disabled connections and retired environments must still permit removing their grant.
            await model.logout(first)
            XCTAssertEqual(calls.withLock { $0 }, [reference])
            XCTAssertEqual(model.error != nil, fails)
            XCTAssertEqual(model.authenticationMessage != nil, !fails)
            XCTAssertFalse(model.busy)
            let current = try await store.read(id: value.id, in: project.scope)
            XCTAssertEqual(current?.revision, first.revision)
            XCTAssertEqual(current?.configuration, value)
            try await NativeJiraLoginOwnership.shared.acquire(value.id)
            await model.logout(first)
            await NativeJiraLoginOwnership.shared.release(value.id)
            XCTAssertNotNil(model.error)
            XCTAssertEqual(calls.withLock { $0.count }, 1, "Logout raced another native window’s sign-in")
            _ = try await store.save(value, in: project.scope, expectedRevision: first.revision)
            await model.logout(first)
            XCTAssertNotNil(model.error)
            XCTAssertEqual(calls.withLock { $0.count }, 1, "A stale row deleted a current grant")
            model.close()
        }
    }

    func testOwnershipRejectsSecondWindowAndReleases() async throws {
        let ownership = NativeJiraLoginOwnership(), id = UUID()
        try await ownership.acquire(id)
        do { try await ownership.acquire(id); XCTFail("Concurrent login accepted") }
        catch { XCTAssertEqual(error as? JiraServiceError, .unavailable) }
        await ownership.release(id)
        try await ownership.acquire(id)
        await ownership.release(id)
    }
}

private actor FakeNativeJiraLogin: NativeJiraLogin {
    let change: @Sendable () async throws -> Void
    private(set) var closed = false
    private(set) var started = false
    init(change: @escaping @Sendable () async throws -> Void) { self.change = change }
    func signIn(validateConfiguration: @escaping @Sendable () async throws -> Void,
                openBrowser: @escaping @Sendable (URL) async throws -> Void) async throws {
        started = true
        try await validateConfiguration()
        try await change()
        try await validateConfiguration()
    }
    func close() async { closed = true }
}
#endif
