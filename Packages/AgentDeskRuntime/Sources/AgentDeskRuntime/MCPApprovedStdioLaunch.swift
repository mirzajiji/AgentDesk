#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

/// Internal Mac integration. The host must retain registered filesystem access for this lifetime.
/// Secret-bearing launches remain unavailable until credential-read policy is integrated.
actor MCPApprovedStdioLaunch {
    private let gate: MCPLaunchPolicySession
    private let configuration: MCPStdioConfiguration
    private let workspaceRoot: URL
    private let projectRoot: URL
    private let resource: ActionFingerprint
    private var connection: MCPNegotiatedStdioConnection?
    private var closed = false
    private var starting = false
    private var launchTask: Task<PolicyExecutionResult<MCPNegotiatedStdioConnection>, any Error>?

    private init(gate: MCPLaunchPolicySession, configuration: MCPStdioConfiguration,
                 workspaceRoot: URL, projectRoot: URL, resource: ActionFingerprint) {
        self.gate = gate; self.configuration = configuration; self.workspaceRoot = workspaceRoot
        self.projectRoot = projectRoot; self.resource = resource
    }
    static func open(configurations: ProjectMCPConfigurationStore<MCPStdioConfiguration>, connectionID: UUID,
                     scope: ProjectScope, environmentID: EnvironmentID, workspaceRoot: URL, projectRoot: URL,
                     authorities: [PolicyAuthority], requesterID: UUID, approvals: ApprovalStore,
                     currentPolicy: @escaping @Sendable () async throws -> PolicySnapshot) async throws -> Self {
        guard let requester = authorities.first(where: { $0.id == requesterID }), case .localUser = requester.kind,
              let record = try await configurations.read(id: connectionID, in: scope), record.configuration.enabled,
              record.configuration.environmentID == environmentID,
              record.configuration.secretEnvironment.isEmpty else { throw AuthorizationError.denied }
        let configuration = record.configuration
        let resource = try MCPLaunchResource.resolve(configuration, scope: scope, workspaceRoot: workspaceRoot, projectRoot: projectRoot)
        let gate = try await MCPLaunchPolicySession.open(configurations: configurations, connectionID: connectionID,
            scope: scope, environmentID: environmentID, authorities: authorities, requesterID: requesterID, approvals: approvals,
            currentPolicy: currentPolicy, resolveResource: { current in
                guard current == configuration else { throw AuthorizationError.stalePolicy }
                return try MCPLaunchResource.resolve(current, scope: scope, workspaceRoot: workspaceRoot, projectRoot: projectRoot).fingerprint
            })
        return Self(gate: gate, configuration: configuration, workspaceRoot: workspaceRoot, projectRoot: projectRoot, resource: resource.fingerprint)
    }
    func prepare() async throws -> PolicyPreparation { try await gate.prepare() }
    func review(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        try await gate.review(id, approve: approve, expectedSequence: expectedSequence)
    }
    func start(approvalID: UUID) async throws -> MCPServerDescription {
        guard !closed, !starting, connection == nil else { throw AuthorizationError.denied }
        starting = true
        defer { starting = false; launchTask = nil }
        let configuration = configuration, workspaceRoot = workspaceRoot, projectRoot = projectRoot, expected = resource
        let gate = gate
        let task = Task { try await gate.execute(approvalID: approvalID) {
            try Task.checkCancellation()
            let resolved = try MCPLaunchResource.resolve(configuration, scope: configuration.scope,
                workspaceRoot: workspaceRoot, projectRoot: projectRoot)
            guard resolved.fingerprint == expected else { throw AuthorizationError.stalePolicy }
            let transport = try MCPStdioTransport(scope: configuration.scope, connectionID: configuration.id,
                executable: resolved.executable, arguments: configuration.arguments, directory: resolved.directory)
            return try await MCPNegotiatedStdioConnection.open(transport: transport)
        }
        }
        launchTask = task
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard case .executed(let opened) = result else { throw AuthorizationError.denied }
        if closed || Task.isCancelled { await opened.close(); throw CancellationError() }
        connection = opened
        return opened.server
    }
    func ping() async throws {
        guard !closed, let connection else { throw MCPProcessError.closed }
        _ = try await connection.ping()
    }
    func close() async {
        closed = true
        let pending = launchTask
        pending?.cancel()
        await gate.close()
        if let pending, case .executed(let opened) = try? await pending.value { await opened.close() }
        await connection?.close()
        connection = nil
    }
}
#endif
