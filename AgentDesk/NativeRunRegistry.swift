#if os(macOS)
import AgentDeskCore
import AgentDeskRuntime
import Foundation

/// Application-local ownership shared across windows. Settings writers stop affected services
/// before replacing execution configuration; the runtime still enforces its project lease.
@MainActor
final class NativeRunRegistry {
    static let shared = NativeRunRegistry()
    private var services: [ProjectScope: NativeRunService] = [:]
    private var changes: [UUID: (scope: ProjectScope, level: ExecutionConfigurationLevel)] = [:]
    func register(_ service: NativeRunService) async throws {
        guard !changes.values.contains(where: { matches(service.scope, change: $0) }) else {
            await service.shutdown(); throw CatalogError.busy
        }
        if let previous = services[service.scope], previous !== service { await previous.shutdown() }
        guard !changes.values.contains(where: { matches(service.scope, change: $0) }) else {
            await service.shutdown(); throw CatalogError.busy
        }
        services[service.scope] = service
    }
    func release(_ service: NativeRunService) {
        if services[service.scope] === service { services.removeValue(forKey: service.scope) }
    }
    func stop(in scope: ProjectScope, level: ExecutionConfigurationLevel) async {
        let affected = services.filter { level == .workspace ? $0.key.workspaceID == scope.workspaceID : $0.key == scope }
        for (scope, service) in affected {
            if services[scope] === service { services.removeValue(forKey: scope) }
            await service.shutdown()
        }
    }
    func changeConfiguration(in scope: ProjectScope, level: ExecutionConfigurationLevel,
                             change: () async throws -> Void) async throws {
        let requested = (scope: scope, level: level)
        guard !changes.values.contains(where: { matches(scope, change: $0) || matches($0.scope, change: requested) }) else {
            throw CatalogError.busy
        }
        let token = UUID(); changes[token] = requested
        defer { changes.removeValue(forKey: token) }
        await stop(in: scope, level: level)
        try await change()
    }
    private func matches(_ scope: ProjectScope, change: (scope: ProjectScope, level: ExecutionConfigurationLevel)) -> Bool {
        change.level == .workspace ? scope.workspaceID == change.scope.workspaceID : scope == change.scope
    }
}
#endif
