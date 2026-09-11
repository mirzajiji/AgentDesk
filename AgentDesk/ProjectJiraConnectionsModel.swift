#if os(macOS)
import AgentDeskCore
import AgentDeskPlugins
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
    private var cursor: UUID?
    private var generation = UUID()
    private let open: () async throws -> NativeJiraConfigurationServices

    init(project: ProjectRecord, open: @escaping () async throws -> NativeJiraConfigurationServices) {
        self.project = project; self.open = open
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
    func close() { generation = UUID(); records = []; environments = []; cursor = nil; hasMore = false; busy = false }
}
#endif
