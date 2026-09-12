import AgentDeskCore
import AgentDeskSecurity
import Foundation

public enum MCPConfigurationError: Error, Equatable, Sendable {
    case unsupportedVersion, invalidConfiguration, scopeMismatch
}

/// Non-secret launch intent. Filesystem resolution and policy approval are required before launch.
public struct MCPStdioConfiguration: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let id: UUID
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let name: String
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: WorkspacePath
    public let secretEnvironment: [String: SecretReference]
    public let enabled: Bool

    public init(id: UUID = UUID(), scope: ProjectScope, environmentID: EnvironmentID, name: String,
                executable: String, arguments: [String] = [], workingDirectory: WorkspacePath,
                secretEnvironment: [String: SecretReference] = [:], enabled: Bool = false) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 256,
              !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              executable.hasPrefix("/"), executable.utf8.count <= 4096,
              !executable.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              executable.split(separator: "/", omittingEmptySubsequences: false).dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              arguments.count <= 128, arguments.allSatisfy({ !$0.contains("\0") && $0.utf8.count <= 8192 }),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 65_536,
              secretEnvironment.count <= 64 else { throw MCPConfigurationError.invalidConfiguration }
        guard workingDirectory.workspaceID == scope.workspaceID else { throw MCPConfigurationError.scopeMismatch }
        for (key, reference) in secretEnvironment {
            guard !key.isEmpty, key.utf8.count <= 128,
                  key.utf8.enumerated().allSatisfy({ index, byte in
                      byte == 95 || (65...90).contains(byte) || (97...122).contains(byte) || (index > 0 && (48...57).contains(byte))
                  }) else { throw MCPConfigurationError.invalidConfiguration }
            guard reference.scope.workspaceID == scope.workspaceID, reference.scope.projectID == scope.projectID,
                  reference.scope.environmentID == environmentID else { throw MCPConfigurationError.scopeMismatch }
        }
        schemaVersion = 1; self.id = id; self.scope = scope; self.environmentID = environmentID
        self.name = name; self.executable = executable; self.arguments = arguments
        self.workingDirectory = workingDirectory; self.secretEnvironment = secretEnvironment; self.enabled = enabled
    }
    private enum CodingKeys: CodingKey {
        case schemaVersion, id, scope, environmentID, name, executable, arguments, workingDirectory, secretEnvironment, enabled
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard try c.decode(Int.self, forKey: .schemaVersion) == 1 else { throw MCPConfigurationError.unsupportedVersion }
        try self.init(id: c.decode(UUID.self, forKey: .id), scope: c.decode(ProjectScope.self, forKey: .scope),
            environmentID: c.decode(EnvironmentID.self, forKey: .environmentID), name: c.decode(String.self, forKey: .name),
            executable: c.decode(String.self, forKey: .executable), arguments: c.decode([String].self, forKey: .arguments),
            workingDirectory: c.decode(WorkspacePath.self, forKey: .workingDirectory),
            secretEnvironment: c.decode([String: SecretReference].self, forKey: .secretEnvironment), enabled: c.decode(Bool.self, forKey: .enabled))
    }
}
