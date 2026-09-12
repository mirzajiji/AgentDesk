import AgentDeskCore
import AgentDeskPersistence
import AgentDeskPlugins
import AgentDeskSecurity
import Foundation

extension PluginPolicySession {
    /// Trusted adapters bind their exact operation to the current persisted configuration and grants.
    static func openStored(configurationStore: ProjectPluginConfigurationStore<JiraConnectionConfiguration>,
                           connectionID: UUID, scope: ProjectScope,
                           authorities: [PolicyAuthority], requesterID: UUID, approvals: ApprovalStore,
                           currentPolicy: @escaping @Sendable () async throws -> PolicySnapshot,
                           prepare: @escaping @Sendable (PluginConfigurationRevision<JiraConnectionConfiguration>, PluginPermissions) throws -> PreparedPluginAction) async throws -> PluginPolicySession {
        let load: @Sendable () async throws -> (PreparedPluginAction, PluginPermissions, PolicySnapshot) = {
            try Task.checkCancellation()
            guard let record = try await configurationStore.read(id: connectionID, in: scope) else {
                throw PluginStorageError.invalidRecord
            }
            guard record.configuration.enabled else { throw AuthorizationError.denied }
            let permissions = try record.configuration.resolvedPermissions()
            let prepared = try prepare(record, permissions)
            guard prepared.connectionID == connectionID, prepared.configurationRevision == record.revision,
                  prepared.action.scope == scope, prepared.action.environmentID == record.configuration.environmentID,
                  prepared.configurationFingerprint == (try ActionFingerprint.canonical(record.configuration)),
                  prepared.permissionsFingerprint == (try ActionFingerprint.canonical(permissions)) else {
                throw AuthorizationError.scopeMismatch
            }
            let policy = try await currentPolicy()
            return (prepared, permissions, policy)
        }
        let (prepared, permissions, policy) = try await load()
        return try PluginPolicySession(prepared: prepared, policy: policy, permissions: permissions,
            authorities: authorities, requesterID: requesterID, store: approvals, validateCurrent: {
                let (current, _, policy) = try await load()
                return (current, policy)
            })
    }
}
