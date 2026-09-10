#if os(macOS)
import AgentDeskCore
import AgentDeskRuntime
import AgentDeskPersistence
import Combine
import Foundation

/// Application-local ownership shared across windows. Settings writers stop affected services
/// before replacing execution configuration; the runtime still enforces its project lease.
struct NativeRunStatus: Identifiable, Equatable {
    let scope: ProjectScope
    let runID: RunID
    let projectName: String
    let state: RunState
    let sequence: Int64
    var id: ProjectScope { scope }
}

@MainActor
final class NativeRunRegistry: ObservableObject {
    static let shared = NativeRunRegistry()
    @Published private(set) var statuses: [ProjectScope: NativeRunStatus] = [:]
    private var presenters: [ProjectScope: () -> Bool] = [:]
    var runningCount: Int { statuses.values.filter { $0.state == .running }.count }
    var approvalCount: Int { statuses.values.filter { $0.state == .waitingForApproval }.count }
    var failedCount: Int { statuses.values.filter { $0.state == .failed }.count }

    /// Only the registered owner may publish its persisted run state. Older observations
    /// cannot overwrite newer state, and a replaced service cannot regain presentation ownership.
    func update(_ run: StoredRun, projectName: String, owner: NativeRunService, present: @escaping () -> Bool) {
        guard services[run.scope] === owner, owner.scope == run.scope else { return }
        if let previous = statuses[run.scope] {
            guard previous.runID == run.id, run.sequence >= previous.sequence else { return }
        }
        statuses[run.scope] = NativeRunStatus(scope: run.scope, runID: run.id,
            projectName: projectName, state: run.state, sequence: run.sequence)
        presenters[run.scope] = present
    }
    @discardableResult
    func focus(_ scope: ProjectScope) -> Bool { presenters[scope]?() ?? false }

    private func removeStatus(_ scope: ProjectScope) {
        statuses.removeValue(forKey: scope); presenters.removeValue(forKey: scope)
    }

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
        if services[service.scope] !== service { removeStatus(service.scope) }
        services[service.scope] = service
    }
    func release(_ service: NativeRunService) {
        if services[service.scope] === service { services.removeValue(forKey: service.scope); removeStatus(service.scope) }
    }
    func stop(in scope: ProjectScope, level: ExecutionConfigurationLevel) async {
        let affected = services.filter { level == .workspace ? $0.key.workspaceID == scope.workspaceID : $0.key == scope }
        for (scope, service) in affected {
            if services[scope] === service { services.removeValue(forKey: scope); removeStatus(scope) }
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
