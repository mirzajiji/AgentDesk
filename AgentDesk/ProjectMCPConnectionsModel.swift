#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import Combine
import Foundation

struct NativeMCPConfigurationServices {
    let store: ProjectMCPConfigurationStore<MCPStdioConfiguration>
    let environments: [ProjectEnvironment]
}

@MainActor final class ProjectMCPConnectionsModel: ObservableObject {
    let project: ProjectRecord
    @Published private(set) var records: [MCPConfigurationRevision<MCPStdioConfiguration>] = []
    @Published private(set) var environments: [ProjectEnvironment] = []
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var hasMore = false
    private var cursor: UUID?
    private var generation = UUID()
    private let open: () async throws -> NativeMCPConfigurationServices
    init(project: ProjectRecord, open: @escaping () async throws -> NativeMCPConfigurationServices) {
        self.project = project; self.open = open
    }
    func load(more: Bool = false) async {
        guard !busy, !more || hasMore else { return }
        let current = generation
        busy = true; error = nil
        defer { if generation == current { busy = false } }
        do {
            let services = try await open()
            guard services.environments.allSatisfy({ $0.scope == project.scope }) else { throw MCPStorageError.scopeMismatch }
            let page = try await services.store.list(in: project.scope, after: more ? cursor : nil)
            try Task.checkCancellation()
            guard generation == current else { return }
            records = more ? records + page.records : page.records
            environments = services.environments; cursor = page.nextID; hasMore = cursor != nil
        } catch {
            guard generation == current else { return }
            records = []; environments = []; cursor = nil; hasMore = false
            self.error = "MCP configuration could not be read. Check the project configuration and try again."
        }
    }
    func save(name: String, executable: String, arguments: [String], directory: String, environment: EnvironmentID,
              enabled: Bool, existing: MCPConfigurationRevision<MCPStdioConfiguration>?) async throws {
        guard !busy else { throw MCPStorageError.staleRevision }
        let current = generation
        busy = true
        defer { if generation == current { busy = false } }
        let services = try await open()
        try Task.checkCancellation()
        guard generation == current else { throw CancellationError() }
        guard services.environments.allSatisfy({ $0.scope == project.scope }),
              services.environments.contains(where: { $0.id == environment }),
              existing.map({ $0.configuration.scope == project.scope && $0.configuration.environmentID == environment }) ?? true else {
            throw MCPStorageError.scopeMismatch
        }
        let value = try MCPStdioConfiguration(id: existing?.configuration.id ?? UUID(), scope: project.scope,
            environmentID: environment, name: name.trimmingCharacters(in: .whitespacesAndNewlines), executable: executable,
            arguments: arguments, workingDirectory: WorkspacePath(workspaceID: project.scope.workspaceID, relativePath: directory),
            secretEnvironment: existing?.configuration.secretEnvironment ?? [:], enabled: enabled)
        _ = try await services.store.save(value, in: project.scope, expectedRevision: existing?.revision)
        let page = try await services.store.list(in: project.scope)
        guard generation == current else { return }
        records = page.records; environments = services.environments; cursor = page.nextID; hasMore = cursor != nil; error = nil
    }
    func cancel() { generation = UUID(); busy = false }
}
#endif
