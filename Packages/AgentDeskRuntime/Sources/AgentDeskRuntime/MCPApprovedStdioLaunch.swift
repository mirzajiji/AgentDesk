#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

/// Scoped, redacted server claims for presentation; capabilities do not grant permissions.
struct MCPServerPresentation: Sendable {
    let mode: MCPProtocolMode
    let name: RedactedText?
    let version: RedactedText?
    let tools: Bool
    let resources: Bool
    let prompts: Bool
}

/// Internal Mac integration. The host retains registered filesystem access for this lifetime.
/// Credential reads require independent readSecret policy permission.
actor MCPApprovedStdioLaunch {
    private struct Opened: Sendable {
        let connection: MCPNegotiatedStdioConnection
        let presentation: MCPServerPresentation
    }
    private let secrets: (any SecretStore)?
    private let gate: MCPLaunchPolicySession
    private let configuration: MCPStdioConfiguration
    private let workspaceRoot: URL
    private let projectRoot: URL
    private let resource: ActionFingerprint
    private var connection: MCPNegotiatedStdioConnection?
    private var closed = false
    private var starting = false
    private var launchTask: Task<PolicyExecutionResult<Opened>, any Error>?

    private init(secrets: (any SecretStore)?, gate: MCPLaunchPolicySession, configuration: MCPStdioConfiguration,
                 workspaceRoot: URL, projectRoot: URL, resource: ActionFingerprint) {
        self.secrets = secrets
        self.gate = gate; self.configuration = configuration; self.workspaceRoot = workspaceRoot
        self.projectRoot = projectRoot; self.resource = resource
    }
    static func open(configurations: ProjectMCPConfigurationStore<MCPStdioConfiguration>, connectionID: UUID,
                     scope: ProjectScope, environmentID: EnvironmentID, workspaceRoot: URL, projectRoot: URL,
                     authorities: [PolicyAuthority], requesterID: UUID, approvals: ApprovalStore,
                     secrets: (any SecretStore)? = nil, currentPolicy: @escaping @Sendable () async throws -> PolicySnapshot) async throws -> Self {
        guard let requester = authorities.first(where: { $0.id == requesterID }), case .localUser = requester.kind,
              let record = try await configurations.read(id: connectionID, in: scope), record.configuration.enabled,
              record.configuration.environmentID == environmentID,
              (record.configuration.secretEnvironment.isEmpty || secrets != nil) else { throw AuthorizationError.denied }
        let configuration = record.configuration
        let resource = try MCPLaunchResource.resolve(configuration, scope: scope, workspaceRoot: workspaceRoot, projectRoot: projectRoot)
        let gate = try await MCPLaunchPolicySession.open(configurations: configurations, connectionID: connectionID,
            scope: scope, environmentID: environmentID, authorities: authorities, requesterID: requesterID, approvals: approvals,
            currentPolicy: currentPolicy, resolveResource: { current in
                guard current == configuration else { throw AuthorizationError.stalePolicy }
                return try MCPLaunchResource.resolve(current, scope: scope, workspaceRoot: workspaceRoot, projectRoot: projectRoot).fingerprint
            })
        return Self(secrets: secrets, gate: gate, configuration: configuration, workspaceRoot: workspaceRoot, projectRoot: projectRoot, resource: resource.fingerprint)
    }
    func prepare() async throws -> PolicyPreparation { try await gate.prepare() }
    func review(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        try await gate.review(id, approve: approve, expectedSequence: expectedSequence)
    }
    func prepareCredentials() async throws -> PolicyPreparation { try await gate.prepareCredentials() }
    func reviewCredentials(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        try await gate.reviewCredentials(id, approve: approve, expectedSequence: expectedSequence)
    }
    func start(approvalID: UUID, credentialApprovalID: UUID? = nil) async throws -> MCPServerPresentation {
        guard !closed, !starting, connection == nil else { throw AuthorizationError.denied }
        starting = true
        defer { starting = false; launchTask = nil }
        let configuration = configuration, workspaceRoot = workspaceRoot, projectRoot = projectRoot, expected = resource
        let gate = gate, secrets = secrets
        let task = Task { try await gate.execute(approvalID: approvalID) {
            try Task.checkCancellation()
            let environment: [String: String]
            if configuration.secretEnvironment.isEmpty { environment = [:] }
            else {
                guard let secrets else { throw AuthorizationError.denied }
                environment = try await gate.environment(store: secrets, approvalID: credentialApprovalID)
            }
            let resolved = try MCPLaunchResource.resolve(configuration, scope: configuration.scope,
                workspaceRoot: workspaceRoot, projectRoot: projectRoot)
            guard resolved.fingerprint == expected else { throw AuthorizationError.stalePolicy }
            let transport = try MCPStdioTransport(scope: configuration.scope, connectionID: configuration.id,
                executable: resolved.executable, arguments: configuration.arguments, directory: resolved.directory, environment: environment)
            let opened = try await MCPNegotiatedStdioConnection.open(transport: transport)
            do {
                let context = RedactionContext(scope: configuration.scope, environmentID: configuration.environmentID, runID: RunID())
                let known = try environment.values.map { try SecretValue(Data($0.utf8)) }
                let redactor = try ContentRedactor(context: context).includingKnownSecrets(known, in: context)
                let server = opened.server
                let presentation = try MCPServerPresentation(mode: server.mode,
                    name: server.name.map { try redactor.redactText($0, in: context) },
                    version: server.version.map { try redactor.redactText($0, in: context) },
                    tools: server.tools, resources: server.resources, prompts: server.prompts)
                return Opened(connection: opened, presentation: presentation)
            } catch { await opened.close(); throw error }
        }
        }
        launchTask = task
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard case .executed(let opened) = result else { throw AuthorizationError.denied }
        if closed || Task.isCancelled { await opened.connection.close(); throw CancellationError() }
        connection = opened.connection
        return opened.presentation
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
        if let pending, case .executed(let opened) = try? await pending.value { await opened.connection.close() }
        await connection?.close()
        connection = nil
    }
}
#endif
