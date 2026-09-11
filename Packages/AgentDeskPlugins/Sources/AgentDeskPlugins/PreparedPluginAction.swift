import AgentDeskCore
import Foundation

/// Prepared identity only; neither this value nor its fingerprints grant transport access.
/// Trusted adapters resolve the resource and sanitize the payload before constructing it.
public struct PreparedPluginAction: Sendable {
    public let action: PolicyAction
    public let capability: PluginCapability
    public let configurationRevision: Int
    public let connectionID: UUID
    public let permissionsFingerprint: ActionFingerprint

    public init(id: UUID = UUID(), configuration: JiraConnectionConfiguration, configurationRevision: Int,
                permissions: PluginPermissions, capability: PluginCapability,
                resource: ActionFingerprint, payload: ActionFingerprint,
                runID: RunID? = nil, agentID: AgentID? = nil) throws {
        guard configuration.enabled, (1...1_000_000).contains(configurationRevision) else {
            throw AuthorizationError.invalidInput
        }
        guard configuration.id == permissions.connectionID, configuration.scope == permissions.scope,
              configuration.environmentID == permissions.environmentID else { throw AuthorizationError.scopeMismatch }
        struct ResourceBinding: Encodable {
            let configuration: JiraConnectionConfiguration
            let revision: Int
            let permissions: PluginPermissions
            let capability: PluginCapability
            let resource: ActionFingerprint
        }
        let binding = try ActionFingerprint.canonical(ResourceBinding(configuration: configuration,
            revision: configurationRevision, permissions: permissions, capability: capability, resource: resource))
        self.action = try PolicyAction(id: id, scope: configuration.scope,
            environmentID: configuration.environmentID, runID: runID, agentID: agentID,
            operation: capability.policyOperation, resource: binding, payload: payload)
        self.capability = capability; self.configurationRevision = configurationRevision
        self.connectionID = configuration.id
        self.permissionsFingerprint = try .canonical(permissions)
    }
}
