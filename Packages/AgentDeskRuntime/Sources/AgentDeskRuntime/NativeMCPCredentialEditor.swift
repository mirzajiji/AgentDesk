#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskSecurity
import Foundation

public enum MCPCredentialEditError: Error, Equatable, Sendable {
    /// Cleanup could not remove this newly allocated reference; its value is never included.
    case cleanupRequired(SecretReference)
}

/// Local administrative credential entry, never an MCP tool or mobile operation.
/// Each replacement allocates a new reference so immutable configuration history is preserved.
public actor NativeMCPCredentialEditor {
    private let configurations: ProjectMCPConfigurationStore<MCPStdioConfiguration>
    private let secrets: any SecretStore
    private let scope: ProjectScope
    private let environmentID: EnvironmentID

    public init(configurations: ProjectMCPConfigurationStore<MCPStdioConfiguration>, secrets: any SecretStore,
                scope: ProjectScope, environmentID: EnvironmentID) throws {
        guard secrets.scope.workspaceID == scope.workspaceID, secrets.scope.projectID == scope.projectID,
              secrets.scope.environmentID == environmentID else { throw SecretStoreError.scopeMismatch }
        self.configurations = configurations; self.secrets = secrets; self.scope = scope; self.environmentID = environmentID
    }

    public func set(connectionID: UUID, expectedRevision: Int, variable: String, value: SecretValue) async throws -> MCPConfigurationRevision<MCPStdioConfiguration> {
        try Task.checkCancellation()
        guard let current = try await configurations.read(id: connectionID, in: scope), current.revision == expectedRevision else {
            throw MCPStorageError.staleRevision
        }
        let old = current.configuration
        guard old.scope == scope, old.environmentID == environmentID else { throw SecretStoreError.scopeMismatch }
        let reference = SecretReference(scope: secrets.scope)
        var bindings = old.secretEnvironment; bindings[variable] = reference
        let updated = try MCPStdioConfiguration(id: old.id, scope: scope, environmentID: environmentID, name: old.name,
            executable: old.executable, arguments: old.arguments, workingDirectory: old.workingDirectory,
            secretEnvironment: bindings, enabled: old.enabled, directoryBase: old.directoryBase)
        let valid = value.withBytes { bytes in
            String(data: bytes, encoding: .utf8) != nil && !bytes.contains(0) && bytes.count + variable.utf8.count <= 65_536
        }
        guard valid else { throw SecretStoreError.invalidValue }
        try Task.checkCancellation()
        do {
            // Even a failing store may have written the new item before reporting failure.
            try await secrets.set(value, for: reference)
            try Task.checkCancellation()
            return try await configurations.save(updated, in: scope, expectedRevision: expectedRevision)
        } catch {
            let original = error, store = secrets
            // Do not inherit cancellation: rollback must still be attempted after UI cancellation.
            let cleanup = Task { try await store.delete(reference) }
            do { try await cleanup.value }
            catch { throw MCPCredentialEditError.cleanupRequired(reference) }
            throw original
        }
    }
}
#endif
