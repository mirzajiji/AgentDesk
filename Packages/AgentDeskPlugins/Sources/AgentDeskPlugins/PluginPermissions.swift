import AgentDeskCore
import Foundation

public struct PluginPermissionRule: Codable, Equatable, Sendable {
    public let capability: PluginCapability
    public let disposition: PolicyDisposition
    public init(_ capability: PluginCapability, _ disposition: PolicyDisposition) {
        self.capability = capability; self.disposition = disposition
    }
}

/// Independent per-connection grants. Missing capabilities deny access.
public struct PluginPermissions: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let revision: UUID
    public let connectionID: UUID
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let rules: [PluginPermissionRule]

    public init(revision: UUID = UUID(), connectionID: UUID, scope: ProjectScope,
                environmentID: EnvironmentID, rules: [PluginPermissionRule]) throws {
        guard rules.count <= PluginCapability.allCases.count,
              Set(rules.map(\.capability)).count == rules.count else { throw AuthorizationError.invalidInput }
        schemaVersion = 1; self.revision = revision; self.connectionID = connectionID
        self.scope = scope; self.environmentID = environmentID; self.rules = rules
    }

    public func disposition(for capability: PluginCapability) -> PolicyDisposition {
        rules.first { $0.capability == capability }?.disposition ?? .deny
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, revision, connectionID, scope, environmentID, rules
    }
    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else { throw AuthorizationError.invalidInput }
        try self.init(revision: values.decode(UUID.self, forKey: .revision),
                      connectionID: values.decode(UUID.self, forKey: .connectionID),
                      scope: values.decode(ProjectScope.self, forKey: .scope),
                      environmentID: values.decode(EnvironmentID.self, forKey: .environmentID),
                      rules: values.decode([PluginPermissionRule].self, forKey: .rules))
    }
}

extension PluginPermissions {
    /// Produces an operation-specific restriction for the existing policy gate.
    /// Approval binding must additionally include this document's revision and exact capability.
    public func restricting(_ base: PolicySnapshot, connectionID requestedConnection: UUID,
                            capability: PluginCapability) throws -> PolicySnapshot {
        try base.validate()
        guard requestedConnection == connectionID, base.scope == scope,
              base.environmentID == environmentID else { throw AuthorizationError.scopeMismatch }
        let selected = capability.policyOperation
        let grant = disposition(for: capability)
        let rules = PolicyOperation.allCases.map { operation -> PolicyRule in
            guard operation == selected else { return PolicyRule(operation, .deny) }
            let original = base.environment.disposition(for: operation)
            let effective: PolicyDisposition = original == .deny || grant == .deny ? .deny
                : (original == .approval || grant == .approval ? .approval : .allow)
            return PolicyRule(operation, effective)
        }
        let environment = try PolicyDocument(revision: base.environment.revision, level: .environment,
            workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environmentID, rules: rules)
        return try PolicySnapshot(workspace: base.workspace, project: base.project, environment: environment,
            environmentKind: base.environmentKind, workspaceLocked: base.workspaceLocked)
    }
}
