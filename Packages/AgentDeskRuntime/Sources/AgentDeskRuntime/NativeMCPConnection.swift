#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

/// Native local-user MCP lifecycle. Folder access comes from the registered project,
/// while both process execution and credential access retain independent policy reviews.
public actor NativeMCPConnection {
    private let launch: MCPApprovedStdioLaunch
    private init(launch: MCPApprovedStdioLaunch) { self.launch = launch }

    public static func open(configurations: ProjectMCPConfigurationStore<MCPStdioConfiguration>, connectionID: UUID,
                            scope: ProjectScope, environmentID: EnvironmentID, workspaceRoot: URL,
                            repositories: ProjectRepositoryRegistry, authorities: [PolicyAuthority], requesterID: UUID,
                            approvals: ApprovalStore, secrets: (any SecretStore)? = nil,
                            currentPolicy: @escaping @Sendable () async throws -> PolicySnapshot) async throws -> NativeMCPConnection {
        // Reject remote callers before acquiring a local folder grant.
        guard let requester = authorities.first(where: { $0.id == requesterID }), case .localUser = requester.kind else {
            throw AuthorizationError.denied
        }
        let repository = try await repositories.access(in: scope)
        let launch = try await MCPApprovedStdioLaunch.open(configurations: configurations, connectionID: connectionID,
            scope: scope, environmentID: environmentID, workspaceRoot: workspaceRoot, repository: repository,
            authorities: authorities, requesterID: requesterID, approvals: approvals, secrets: secrets, currentPolicy: currentPolicy)
        if Task.isCancelled { await launch.close(); throw CancellationError() }
        return NativeMCPConnection(launch: launch)
    }
    public func prepare() async throws -> PolicyPreparation { try await launch.prepare() }
    public func review(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        try await launch.review(id, approve: approve, expectedSequence: expectedSequence)
    }
    public func prepareCredentials() async throws -> PolicyPreparation { try await launch.prepareCredentials() }
    public func reviewCredentials(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        try await launch.reviewCredentials(id, approve: approve, expectedSequence: expectedSequence)
    }
    public func start(approvalID: UUID, credentialApprovalID: UUID? = nil) async throws -> MCPServerPresentation {
        try await launch.start(approvalID: approvalID, credentialApprovalID: credentialApprovalID)
    }
    public func ping() async throws { try await launch.ping() }
    /// Await before releasing the owner or switching projects.
    public func close() async { await launch.close() }
}
#endif
