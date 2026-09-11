#if os(macOS)
import AgentDeskCore
import AgentDeskPlugins
import AgentDeskSecurity
import Combine
import Foundation

struct NativeJiraConfigurationServices {
    let store: ProjectPluginConfigurationStore<JiraConnectionConfiguration>
    let environments: [ProjectEnvironment]
}

@MainActor
final class ProjectJiraConnectionsModel: ObservableObject {
    let project: ProjectRecord
    @Published private(set) var records: [PluginConfigurationRevision<JiraConnectionConfiguration>] = []
    @Published private(set) var environments: [ProjectEnvironment] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = false
    @Published private(set) var authenticationMessage: String?
    private var loginTask: Task<Void, Never>?
    private let makeLogin: (JiraConnectionConfiguration, JiraOAuthRegistration) throws -> any NativeJiraLogin
    private var cursor: UUID?
    private var generation = UUID()
    private let open: () async throws -> NativeJiraConfigurationServices

    init(project: ProjectRecord,
         makeLogin: @escaping (JiraConnectionConfiguration, JiraOAuthRegistration) throws -> any NativeJiraLogin = { configuration, registration in
             guard let reference = configuration.credential else { throw PluginConfigurationError.credentialScopeMismatch }
             return try NativeJiraLoginSession(configuration: configuration, registration: registration,
                                       store: KeychainSecretStore(scope: reference.scope))
         }, open: @escaping () async throws -> NativeJiraConfigurationServices) {
        self.project = project; self.open = open; self.makeLogin = makeLogin
    }
    func load(more: Bool = false) async {
        guard !busy, !more || hasMore else { return }
        let current = generation
        busy = true; error = nil
        defer { if generation == current { busy = false } }
        do {
            let services = try await open()
            guard services.environments.allSatisfy({ $0.scope == project.scope }) else { throw PluginStorageError.scopeMismatch }
            let page = try await services.store.list(in: project.scope, after: more ? cursor : nil)
            try Task.checkCancellation()
            guard generation == current else { return }
            environments = services.environments
            records = more ? records + page.records : page.records
            cursor = page.nextID; hasMore = cursor != nil
        } catch {
            guard generation == current else { return }
            records = []; environments = []; cursor = nil; hasMore = false
            self.error = "Connections could not be read. Check the project’s local configuration and try again."
        }
    }
    func save(instance: String, environment: EnvironmentID, enabled: Bool,
              existing: PluginConfigurationRevision<JiraConnectionConfiguration>?) async throws {
        guard !busy else { throw PluginStorageError.staleRevision }
        let current = generation
        busy = true
        defer { if generation == current { busy = false } }
        let services = try await open()
        try Task.checkCancellation()
        guard generation == current, services.environments.contains(where: { $0.id == environment && $0.scope == project.scope }) else {
            throw PluginStorageError.scopeMismatch
        }
        let text = instance.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.path.isEmpty || parts.path == "/" else { throw PluginConfigurationError.invalidEndpoint }
        if let existing {
            guard existing.configuration.scope == project.scope, existing.configuration.environmentID == environment else {
                throw PluginStorageError.scopeMismatch
            }
            // A saved grant must not silently change its site association through the configuration editor.
            guard existing.configuration.credential == nil || existing.configuration.instance == url else {
                throw PluginConfigurationError.credentialScopeMismatch
            }
        }
        let value = try JiraConnectionConfiguration(id: existing?.configuration.id ?? UUID(), scope: project.scope,
            environmentID: environment, instance: url, credential: existing?.configuration.credential, enabled: enabled)
        _ = try await services.store.save(value, in: project.scope, expectedRevision: existing?.revision)
        let page = try await services.store.list(in: project.scope)
        guard generation == current else { return }
        environments = services.environments; records = page.records; cursor = page.nextID; hasMore = cursor != nil
        error = nil
    }
    func signIn(_ record: PluginConfigurationRevision<JiraConnectionConfiguration>, registration: JiraOAuthRegistration,
                openBrowser: @escaping @Sendable (URL) async throws -> Void) {
        guard !busy else { return }
        let current = generation
        busy = true; authenticationMessage = "Waiting for Jira sign-in…"; error = nil
        loginTask = Task { [weak self] in
            guard let self else { return }
            let id = record.configuration.id
            var owned = false
            var login: (any NativeJiraLogin)?
            do {
                try await NativeJiraLoginOwnership.shared.acquire(id); owned = true
                try await validate(record, generation: current)
                let services = try await open()
                var prepared = record
                if record.configuration.credential == nil {
                    let value = record.configuration
                    let scope = try SecretScope(workspaceID: project.workspaceID, projectID: project.id, environmentID: value.environmentID)
                    let bound = try JiraConnectionConfiguration(id: id, scope: project.scope, environmentID: value.environmentID,
                        instance: value.instance, credential: SecretReference(scope: scope), enabled: value.enabled)
                    try Task.checkCancellation()
                    prepared = try await services.store.save(bound, in: project.scope, expectedRevision: record.revision)
                }
                let expected = prepared
                try await validate(expected, generation: current)
                let operation = try makeLogin(expected.configuration, registration)
                login = operation
                try await operation.signIn(validateConfiguration: { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.validate(expected, generation: current)
                }, openBrowser: openBrowser)
                if generation == current { authenticationMessage = "Signed in to Jira. Runtime permissions still apply." }
            } catch {
                if generation == current {
                    authenticationMessage = nil
                    self.error = error is CancellationError ? "Sign-in cancelled." : "Jira sign-in did not finish. Refresh the connection and try again."
                }
            }
            await login?.close()
            if owned { await NativeJiraLoginOwnership.shared.release(id) }
            if generation == current {
                // A cancelled browser task must still refresh its reserved reference.
                let refreshed = await Task { @MainActor () -> ([ProjectEnvironment], PluginConfigurationPage<JiraConnectionConfiguration>)? in
                    do {
                        let services = try await self.open()
                        guard services.environments.allSatisfy({ $0.scope == self.project.scope }) else {
                            throw PluginStorageError.scopeMismatch
                        }
                        let page = try await services.store.list(in: self.project.scope)
                        return (services.environments, page)
                    } catch { return nil }
                }.value
                guard generation == current else { return }
                if let (environments, page) = refreshed {
                    self.environments = environments; records = page.records
                    cursor = page.nextID; hasMore = cursor != nil
                } else {
                    records = []; environments = []; cursor = nil; hasMore = false
                    error = "Connections could not be refreshed after sign-in. Try Refresh."
                }
                busy = false; loginTask = nil
            }
        }
    }
    private func validate(_ record: PluginConfigurationRevision<JiraConnectionConfiguration>, generation expected: UUID) async throws {
        try Task.checkCancellation()
        guard generation == expected, record.configuration.scope == project.scope, record.configuration.enabled else {
            throw PluginStorageError.staleRevision
        }
        let services = try await open()
        guard services.environments.contains(where: { $0.scope == project.scope && $0.id == record.configuration.environmentID }),
              let latest = try await services.store.read(id: record.configuration.id, in: project.scope),
              latest.revision == record.revision, latest.configuration == record.configuration else {
            throw PluginStorageError.staleRevision
        }
        try Task.checkCancellation()
        guard generation == expected else { throw CancellationError() }
    }
    func cancelSignIn() { loginTask?.cancel() }
    func close() { loginTask?.cancel(); authenticationMessage = nil; generation = UUID(); records = []; environments = []; cursor = nil; hasMore = false; busy = false }
}
#endif
