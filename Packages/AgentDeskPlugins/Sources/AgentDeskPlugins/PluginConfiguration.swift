import AgentDeskCore
import AgentDeskSecurity
import Foundation

public enum PluginConfigurationError: Error, Equatable, Sendable {
    case unsupportedVersion, invalidEndpoint, credentialScopeMismatch
}

/// A saved instance is configuration, never evidence of authentication or health.
/// The initial adapter is Jira; additional providers require their own validated setup types.
public struct JiraConnectionConfiguration: ScopedPluginConfiguration, Equatable {
    public let schemaVersion: Int
    public let id: UUID
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let instance: URL
    public let credential: SecretReference?
    public let enabled: Bool

    public init(id: UUID = UUID(), scope: ProjectScope, environmentID: EnvironmentID,
                instance: URL, credential: SecretReference? = nil, enabled: Bool = false) throws {
        guard let parts = URLComponents(url: instance, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.port.map({ (1...65535).contains($0) }) ?? true,
              instance.absoluteString.utf8.count <= 2048 else {
            throw PluginConfigurationError.invalidEndpoint
        }
        if let credential {
            guard credential.scope.workspaceID == scope.workspaceID,
                  credential.scope.projectID == scope.projectID,
                  credential.scope.environmentID == environmentID else {
                throw PluginConfigurationError.credentialScopeMismatch
            }
        }
        self.schemaVersion = 1; self.id = id; self.scope = scope
        self.environmentID = environmentID; self.instance = instance
        self.credential = credential; self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, id, scope, environmentID, instance, credential, enabled
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        guard try values.decode(Int.self, forKey: .schemaVersion) == 1 else {
            throw PluginConfigurationError.unsupportedVersion
        }
        try self.init(id: values.decode(UUID.self, forKey: .id),
                      scope: values.decode(ProjectScope.self, forKey: .scope),
                      environmentID: values.decode(EnvironmentID.self, forKey: .environmentID),
                      instance: values.decode(URL.self, forKey: .instance),
                      credential: values.decodeIfPresent(SecretReference.self, forKey: .credential),
                      enabled: values.decode(Bool.self, forKey: .enabled))
    }
}
