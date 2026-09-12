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

struct NativeJiraCheck: Sendable {
    let revision: Int
    let capabilities: Set<PluginCapability>
    let checkedAt: Date
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
    @Published private(set) var checks: [UUID: NativeJiraCheck] = [:]
    private let probe: @Sendable (JiraConnectionConfiguration) async throws -> Set<PluginCapability>
    private var checkTask: Task<Set<PluginCapability>, any Error>?
    private var loginTask: Task<Void, Never>?
    private let makeLogin: (JiraConnectionConfiguration, JiraOAuthRegistration) throws -> any NativeJiraLogin
    private let removeGrant: @Sendable (SecretReference) async throws -> Void
    private var cursor: UUID?
    private var generation = UUID()
    private let open: () async throws -> NativeJiraConfigurationServices

    init(project: ProjectRecord,
         makeLogin: @escaping (JiraConnectionConfiguration, JiraOAuthRegistration) throws -> any NativeJiraLogin = { configuration, registration in
             guard let reference = configuration.credential else { throw PluginConfigurationError.credentialScopeMismatch }
             return try NativeJiraLoginSession(configuration: configuration, registration: registration,
                                       store: KeychainSecretStore(scope: reference.scope))
         }, removeGrant: @escaping @Sendable (SecretReference) async throws -> Void = { reference in
             try await KeychainSecretStore(scope: reference.scope).delete(reference)
         }, probe: @escaping @Sendable (JiraConnectionConfiguration) async throws -> Set<PluginCapability> = { configuration in
             guard let reference = configuration.credential else { throw PluginConnectionError.notConfigured }
             let adapter = JiraCloudAdapter(store: KeychainSecretStore(scope: reference.scope))
             let session = try await adapter.connect(configuration)
             let capabilities = session.capabilities
             await session.close()
             try Task.checkCancellation()
             return capabilities
         }, open: @escaping () async throws -> NativeJiraConfigurationServices) {
        self.project = project; self.open = open; self.makeLogin = makeLogin; self.removeGrant = removeGrant; self.probe = probe
    }
    func load(more: Bool = false) async {
        guard !busy, !more || hasMore else { return }
        let current = generation
        busy = true; error = nil; checks = [:]
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
        busy = true; checks = [:]
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
            environmentID: environment, instance: url, credential: existing?.configuration.credential, enabled: enabled, permissions: existing?.configuration.permissions)
        _ = try await services.store.save(value, in: project.scope, expectedRevision: existing?.revision)
        let page = try await services.store.list(in: project.scope)
        guard generation == current else { return }
        environments = services.environments; records = page.records; cursor = page.nextID; hasMore = cursor != nil
        error = nil
    }
    func savePermissions(_ rules: [PluginPermissionRule], for record: PluginConfigurationRevision<JiraConnectionConfiguration>) async throws {
        guard !busy else { throw PluginStorageError.staleRevision }
        busy = true
        let current = generation
        defer { if generation == current { busy = false } }
        let value = record.configuration
        guard value.scope == project.scope else { throw PluginStorageError.scopeMismatch }
        let services = try await open()
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        let permissions = try PluginPermissions(connectionID: value.id, scope: value.scope, environmentID: value.environmentID, rules: rules)
        let changed = try JiraConnectionConfiguration(id: value.id, scope: value.scope, environmentID: value.environmentID,
            instance: value.instance, credential: value.credential, enabled: value.enabled, permissions: permissions)
        let saved = try await services.store.save(changed, in: project.scope, expectedRevision: record.revision)
        guard generation == current else { return }
        if let index = records.firstIndex(where: { $0.configuration.id == value.id }) { records[index] = saved }
        checks[value.id] = nil; authenticationMessage = nil; error = nil
    }

    func signIn(_ record: PluginConfigurationRevision<JiraConnectionConfiguration>, registration: JiraOAuthRegistration,
                openBrowser: @escaping @Sendable (URL) async throws -> Void) {
        authenticate(record, registration: registration, refreshing: false, openBrowser: openBrowser)
    }
    func refreshGrant(_ record: PluginConfigurationRevision<JiraConnectionConfiguration>, registration: JiraOAuthRegistration) {
        authenticate(record, registration: registration, refreshing: true, openBrowser: { _ in throw JiraServiceError.unavailable })
    }
    private func authenticate(_ record: PluginConfigurationRevision<JiraConnectionConfiguration>, registration: JiraOAuthRegistration,
                              refreshing: Bool, openBrowser: @escaping @Sendable (URL) async throws -> Void) {
        guard !busy else { return }
        let current = generation
        checks[record.configuration.id] = nil
        busy = true; authenticationMessage = refreshing ? "Refreshing Jira grant…" : "Waiting for Jira sign-in…"; error = nil
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
                    guard !refreshing else { throw PluginConnectionError.notConfigured }
                    let value = record.configuration
                    let scope = try SecretScope(workspaceID: project.workspaceID, projectID: project.id, environmentID: value.environmentID)
                    let bound = try JiraConnectionConfiguration(id: id, scope: project.scope, environmentID: value.environmentID,
                        instance: value.instance, credential: SecretReference(scope: scope), enabled: value.enabled, permissions: value.permissions)
                    try Task.checkCancellation()
                    prepared = try await services.store.save(bound, in: project.scope, expectedRevision: record.revision)
                }
                let expected = prepared
                try await validate(expected, generation: current)
                let operation = try makeLogin(expected.configuration, registration)
                login = operation
                let revalidate: @Sendable () async throws -> Void = { [weak self] in
                    guard let self else { throw CancellationError() }
                    try await self.validate(expected, generation: current)
                }
                if refreshing { try await operation.refresh(validateConfiguration: revalidate) }
                else { try await operation.signIn(validateConfiguration: revalidate, openBrowser: openBrowser) }
                if generation == current {
                    authenticationMessage = refreshing ? "Jira grant refreshed. Runtime permissions still apply." : "Signed in to Jira. Runtime permissions still apply."
                }
            } catch {
                if generation == current {
                    authenticationMessage = nil
                    self.error = refreshing ? "Jira grant refresh did not finish. Sign in again if the previous grant was consumed." :
                        error is CancellationError ? "Sign-in cancelled." : "Jira sign-in did not finish. Refresh the connection and try again."
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
    func testConnection(_ record: PluginConfigurationRevision<JiraConnectionConfiguration>) async {
        guard !busy else { return }
        let current = generation, id = record.configuration.id
        busy = true; error = nil; authenticationMessage = nil; checks[id] = nil
        var owned = false
        do {
            try await NativeJiraLoginOwnership.shared.acquire(id); owned = true
            try await validate(record, generation: current)
            guard record.configuration.credential != nil else { throw PluginConnectionError.notConfigured }
            let probe = probe, configuration = record.configuration
            let operation = Task { try await probe(configuration) }
            checkTask = operation
            let capabilities = try await withTaskCancellationHandler { try await operation.value } onCancel: { operation.cancel() }
            try await validate(record, generation: current)
            checks[id] = NativeJiraCheck(revision: record.revision, capabilities: capabilities, checkedAt: Date())
        } catch {
            if generation == current {
                if error as? PluginConnectionError == .authenticationExpired {
                    self.error = "The Jira grant is missing or expired. Sign in again."
                } else {
                    self.error = "Jira connection test failed. Check configuration and authentication, then try again."
                }
            }
        }
        if owned { await NativeJiraLoginOwnership.shared.release(id) }
        if generation == current { checkTask = nil; busy = false }
    }

    func logout(_ record: PluginConfigurationRevision<JiraConnectionConfiguration>) async {
        await removeAuthentication(record, reset: false)
    }
    func resetConnection(_ record: PluginConfigurationRevision<JiraConnectionConfiguration>) async {
        await removeAuthentication(record, reset: true)
    }
    private func removeAuthentication(_ record: PluginConfigurationRevision<JiraConnectionConfiguration>, reset: Bool) async {
        guard !busy else { return }
        busy = true; error = nil; authenticationMessage = nil; checks[record.configuration.id] = nil
        let current = generation, id = record.configuration.id
        var owned = false
        do {
            try await NativeJiraLoginOwnership.shared.acquire(id); owned = true
            try Task.checkCancellation()
            guard generation == current, record.configuration.scope == project.scope else { throw PluginStorageError.scopeMismatch }
            let services = try await open()
            guard let latest = try await services.store.read(id: id, in: project.scope),
                  latest.revision == record.revision, latest.configuration == record.configuration else {
                throw PluginStorageError.staleRevision
            }
            try Task.checkCancellation()
            guard generation == current else { throw CancellationError() }
            if let reference = latest.configuration.credential { try await removeGrant(reference) }
            if reset {
                try Task.checkCancellation()
                guard generation == current else { throw CancellationError() }
                let value = latest.configuration
                let cleared = try JiraConnectionConfiguration(id: value.id, scope: value.scope, environmentID: value.environmentID,
                    instance: value.instance, credential: nil, enabled: false, permissions: value.permissions)
                let saved = try await services.store.save(cleared, in: project.scope, expectedRevision: latest.revision)
                if generation == current, let index = records.firstIndex(where: { $0.configuration.id == id }) { records[index] = saved }
            }
            if generation == current {
                authenticationMessage = reset ? "Connection reset and disabled. Configuration history is preserved." :
                    "Local Jira grant removed. Your browser session and Atlassian consent are unchanged."
            }
        } catch {
            if generation == current {
                self.error = reset ? "Reset did not finish. The local grant may already be removed; refresh the connection before retrying." :
                    "Could not remove the local Jira grant. Finish any active sign-in, refresh, and try again."
            }
        }
        if owned { await NativeJiraLoginOwnership.shared.release(id) }
        if generation == current { busy = false }
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
    func close() { checkTask?.cancel(); checks = [:]; loginTask?.cancel(); authenticationMessage = nil; generation = UUID(); records = []; environments = []; cursor = nil; hasMore = false; busy = false }
}
#endif
