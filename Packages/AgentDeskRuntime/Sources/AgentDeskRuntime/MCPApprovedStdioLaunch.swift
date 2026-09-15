#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

/// Scoped, redacted server claims for presentation; capabilities do not grant permissions.
public struct MCPServerPresentation: Sendable {
    public let mode: MCPProtocolMode
    public let name: RedactedText?
    public let version: RedactedText?
    public let tools: Bool
    public let resources: Bool
    public let prompts: Bool
}

/// Display-only server claims. Names are redacted labels, never executable tool identifiers.
public struct MCPToolPresentation: Sendable {
    public let name: RedactedText
    public let title: RedactedText?
    public let description: RedactedText?
    public let readOnlyHint: Bool?
    public let destructiveHint: Bool?
}
public struct MCPToolCatalogPresentation: Sendable {
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let connectionID: UUID
    public let tools: [MCPToolPresentation]
}

/// Prompt metadata is display-only, never adopted as instructions by discovery.
public struct MCPPromptPresentation: Sendable {
    public let name: RedactedText
    public let title: RedactedText?
    public let description: RedactedText?
    public let arguments: [MCPPromptArgumentPresentation]?
}
public struct MCPPromptArgumentPresentation: Sendable {
    public let name: RedactedText
    public let title: RedactedText?
    public let description: RedactedText?
    public let required: Bool?
}
public struct MCPPromptCatalogPresentation: Sendable {
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let connectionID: UUID
    public let prompts: [MCPPromptPresentation]
}

/// Redacted metadata only. URI labels are not executable URLs or filesystem grants.
public struct MCPResourcePresentation: Sendable {
    public let id = UUID()
    public let uri: RedactedText
    public let name: RedactedText
    public let title: RedactedText?
    public let description: RedactedText?
    public let mimeType: RedactedText?
    public let sizeBytes: RedactedText?
}
public struct MCPResourceCatalogPresentation: Sendable {
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let connectionID: UUID
    public let resources: [MCPResourcePresentation]
}

/// Redacted template descriptions; no expansion or resource access is performed.
public struct MCPResourceTemplatePresentation: Sendable {
    public let id = UUID()
    public let uriTemplate: RedactedText
    public let name: RedactedText
    public let title: RedactedText?
    public let description: RedactedText?
    public let mimeType: RedactedText?
}
public struct MCPResourceTemplateCatalogPresentation: Sendable {
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let connectionID: UUID
    public let resourceTemplates: [MCPResourceTemplatePresentation]
}

/// Content is untrusted display data. Binary payloads are withheld from presentation.
public enum MCPResourceBodyPresentation: Sendable {
    case text(RedactedText)
    case binary(byteCount: RedactedText)
}
public struct MCPResourceContentPresentation: Sendable {
    public let uri: RedactedText
    public let mimeType: RedactedText?
    public let body: MCPResourceBodyPresentation
}
public struct MCPResourceReadPresentation: Sendable {
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let connectionID: UUID
    public let resourceID: UUID
    public let contents: [MCPResourceContentPresentation]
}

/// Internal Mac integration. The host retains registered filesystem access for this lifetime.
/// Credential reads require independent readSecret policy permission.
actor MCPApprovedStdioLaunch {
    private struct Opened: Sendable {
        let connection: MCPNegotiatedStdioConnection
        let presentation: MCPServerPresentation
        let redactor: ContentRedactor
    }
    private let secrets: (any SecretStore)?
    private let gate: MCPLaunchPolicySession
    private let configuration: MCPStdioConfiguration
    private let workspaceRoot: URL
    private let projectRoot: URL
    private let resource: ActionFingerprint
    private var connection: MCPNegotiatedStdioConnection?
    private var redactor: ContentRedactor?
    private var repositoryAccess: RepositoryAccess?
    private var resourceURIs: [UUID: String] = [:]
    private var resourceGeneration = UUID()
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
    /// Owns the registered folder grant until process cleanup completes.
    static func open(configurations: ProjectMCPConfigurationStore<MCPStdioConfiguration>, connectionID: UUID,
                     scope: ProjectScope, environmentID: EnvironmentID, workspaceRoot: URL, repository: RepositoryAccess,
                     authorities: [PolicyAuthority], requesterID: UUID, approvals: ApprovalStore,
                     secrets: (any SecretStore)? = nil, currentPolicy: @escaping @Sendable () async throws -> PolicySnapshot) async throws -> Self {
        guard repository.registration.scope == scope else { throw AuthorizationError.denied }
        let launch = try await open(configurations: configurations, connectionID: connectionID,
            scope: scope, environmentID: environmentID, workspaceRoot: workspaceRoot, projectRoot: repository.directory,
            authorities: authorities, requesterID: requesterID, approvals: approvals, secrets: secrets, currentPolicy: currentPolicy)
        await launch.retain(repository)
        return launch
    }
    private func retain(_ repository: RepositoryAccess) { repositoryAccess = repository }
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
                return Opened(connection: opened, presentation: presentation, redactor: redactor)
            } catch { await opened.close(); throw error }
        }
        }
        launchTask = task
        let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard case .executed(let opened) = result else { throw AuthorizationError.denied }
        if closed || Task.isCancelled { await opened.connection.close(); throw CancellationError() }
        connection = opened.connection
        redactor = opened.redactor
        return opened.presentation
    }
    func prepareDiscovery() async throws -> PolicyPreparation {
        guard !closed, connection != nil else { throw MCPProcessError.closed }
        return try await gate.prepareDiscovery()
    }
    func reviewDiscovery(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        guard !closed, connection != nil else { throw MCPProcessError.closed }
        return try await gate.reviewDiscovery(id, approve: approve, expectedSequence: expectedSequence)
    }
    func discoverTools(approvalID: UUID? = nil) async throws -> MCPToolCatalogPresentation {
        guard !closed, let connection, let redactor else { throw MCPProcessError.closed }
        let environment = configuration.environmentID
        let result = try await gate.discover(approvalID: approvalID) {
            let catalog = try await connection.discoverTools(environmentID: environment)
            let tools = try catalog.tools.map { tool in
                try Task.checkCancellation()
                return try MCPToolPresentation(name: redactor.redactText(tool.name, in: redactor.context),
                    title: tool.title.map { try redactor.redactText($0, in: redactor.context) },
                    description: tool.description.map { try redactor.redactText($0, in: redactor.context) },
                    readOnlyHint: tool.readOnlyHint, destructiveHint: tool.destructiveHint)
            }
            return MCPToolCatalogPresentation(scope: catalog.scope, environmentID: catalog.environmentID,
                connectionID: catalog.connectionID, tools: tools)
        }
        try Task.checkCancellation()
        guard !closed, case .executed(let catalog) = result else { throw AuthorizationError.denied }
        return catalog
    }
    func preparePromptDiscovery() async throws -> PolicyPreparation {
        guard !closed, connection != nil else { throw MCPProcessError.closed }
        return try await gate.prepareDiscovery(kind: .prompts)
    }
    func reviewPromptDiscovery(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        guard !closed, connection != nil else { throw MCPProcessError.closed }
        return try await gate.reviewDiscovery(id, approve: approve, expectedSequence: expectedSequence, kind: .prompts)
    }
    func discoverPrompts(approvalID: UUID? = nil) async throws -> MCPPromptCatalogPresentation {
        guard !closed, let connection, let redactor else { throw MCPProcessError.closed }
        let environment = configuration.environmentID
        let result = try await gate.discover(approvalID: approvalID, kind: .prompts) {
            let catalog = try await connection.discoverPrompts(environmentID: environment)
            let prompts = try catalog.prompts.map { prompt in
                try Task.checkCancellation()
                return try MCPPromptPresentation(name: redactor.redactText(prompt.name, in: redactor.context),
                    title: prompt.title.map { try redactor.redactText($0, in: redactor.context) },
                    description: prompt.description.map { try redactor.redactText($0, in: redactor.context) },
                    arguments: prompt.arguments.map { arguments in
                        try arguments.map { argument in
                            try Task.checkCancellation()
                            return try MCPPromptArgumentPresentation(name: redactor.redactText(argument.name, in: redactor.context),
                                title: argument.title.map { try redactor.redactText($0, in: redactor.context) },
                                description: argument.description.map { try redactor.redactText($0, in: redactor.context) },
                                required: argument.required)
                        }
                    })
            }
            return MCPPromptCatalogPresentation(scope: catalog.scope, environmentID: catalog.environmentID,
                connectionID: catalog.connectionID, prompts: prompts)
        }
        try Task.checkCancellation()
        guard !closed, case .executed(let catalog) = result else { throw AuthorizationError.denied }
        return catalog
    }
    func prepareResourceDiscovery() async throws -> PolicyPreparation {
        guard !closed, connection != nil else { throw MCPProcessError.closed }
        return try await gate.prepareDiscovery(kind: .resources)
    }
    func reviewResourceDiscovery(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        guard !closed, connection != nil else { throw MCPProcessError.closed }
        return try await gate.reviewDiscovery(id, approve: approve, expectedSequence: expectedSequence, kind: .resources)
    }
    func discoverResources(approvalID: UUID? = nil) async throws -> MCPResourceCatalogPresentation {
        guard !closed, let connection, let redactor else { throw MCPProcessError.closed }
        resourceURIs.removeAll()
        resourceGeneration = UUID()
        let generation = resourceGeneration
        let environment = configuration.environmentID
        let result = try await gate.discover(approvalID: approvalID, kind: .resources) {
            let catalog = try await connection.discoverResources(environmentID: environment)
            let resources = try catalog.resources.map { resource in
                try Task.checkCancellation()
                return try MCPResourcePresentation(uri: redactor.redactText(resource.uri, in: redactor.context),
                    name: redactor.redactText(resource.name, in: redactor.context),
                    title: resource.title.map { try redactor.redactText($0, in: redactor.context) },
                    description: resource.description.map { try redactor.redactText($0, in: redactor.context) },
                    mimeType: resource.mimeType.map { try redactor.redactText($0, in: redactor.context) },
                    sizeBytes: resource.size.map { try redactor.redactText(String($0), in: redactor.context) })
            }
            let bindings = Dictionary(uniqueKeysWithValues: zip(resources, catalog.resources).map { ($0.id, $1.uri) })
            return (MCPResourceCatalogPresentation(scope: catalog.scope, environmentID: catalog.environmentID,
                connectionID: catalog.connectionID, resources: resources), bindings)
        }
        try Task.checkCancellation()
        guard !closed, generation == resourceGeneration, case .executed(let (catalog, bindings)) = result else { throw AuthorizationError.denied }
        resourceURIs = bindings
        return catalog
    }
    func prepareResourceTemplateDiscovery() async throws -> PolicyPreparation {
        guard !closed, connection != nil else { throw MCPProcessError.closed }
        return try await gate.prepareDiscovery(kind: .resourceTemplates)
    }
    func reviewResourceTemplateDiscovery(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        guard !closed, connection != nil else { throw MCPProcessError.closed }
        return try await gate.reviewDiscovery(id, approve: approve, expectedSequence: expectedSequence, kind: .resourceTemplates)
    }
    func discoverResourceTemplates(approvalID: UUID? = nil) async throws -> MCPResourceTemplateCatalogPresentation {
        guard !closed, let connection, let redactor else { throw MCPProcessError.closed }
        let environment = configuration.environmentID
        let result = try await gate.discover(approvalID: approvalID, kind: .resourceTemplates) {
            let catalog = try await connection.discoverResourceTemplates(environmentID: environment)
            let resources = try catalog.resourceTemplates.map { resource in
                try Task.checkCancellation()
                return try MCPResourceTemplatePresentation(uriTemplate: redactor.redactText(resource.uriTemplate, in: redactor.context),
                    name: redactor.redactText(resource.name, in: redactor.context),
                    title: resource.title.map { try redactor.redactText($0, in: redactor.context) },
                    description: resource.description.map { try redactor.redactText($0, in: redactor.context) },
                    mimeType: resource.mimeType.map { try redactor.redactText($0, in: redactor.context) })
            }
            return MCPResourceTemplateCatalogPresentation(scope: catalog.scope, environmentID: catalog.environmentID,
                connectionID: catalog.connectionID, resourceTemplates: resources)
        }
        try Task.checkCancellation()
        guard !closed, case .executed(let catalog) = result else { throw AuthorizationError.denied }
        return catalog
    }
    private func resourceURI(_ id: UUID) throws -> String {
        guard !closed, connection != nil else { throw MCPProcessError.closed }
        guard let uri = resourceURIs[id] else { throw AuthorizationError.invalidInput }
        return uri
    }
    func prepareResourceRead(resourceID: UUID) async throws -> PolicyPreparation {
        try await gate.prepareResourceRead(uri: resourceURI(resourceID))
    }
    func reviewResourceRead(_ id: UUID, resourceID: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        try await gate.reviewResourceRead(id, uri: resourceURI(resourceID), approve: approve, expectedSequence: expectedSequence)
    }
    func readResource(resourceID: UUID, approvalID: UUID? = nil) async throws -> MCPResourceReadPresentation {
        let uri = try resourceURI(resourceID)
        guard let connection, let redactor else { throw MCPProcessError.closed }
        let environment = configuration.environmentID
        let result = try await gate.readResource(uri: uri, approvalID: approvalID) {
            let read = try await connection.readResource(uri: uri, environmentID: environment)
            let contents = try read.contents.map { content in
                try Task.checkCancellation()
                let body: MCPResourceBodyPresentation
                switch content.body {
                case .text(let text): body = .text(try redactor.redactText(text, in: redactor.context))
                case .blob(let bytes): body = .binary(byteCount: try redactor.redactText(String(bytes.count), in: redactor.context))
                }
                return try MCPResourceContentPresentation(uri: redactor.redactText(content.uri, in: redactor.context),
                    mimeType: content.mimeType.map { try redactor.redactText($0, in: redactor.context) }, body: body)
            }
            return MCPResourceReadPresentation(scope: read.scope, environmentID: read.environmentID,
                connectionID: read.connectionID, resourceID: resourceID, contents: contents)
        }
        try Task.checkCancellation()
        guard try resourceURI(resourceID) == uri, case .executed(let presentation) = result else { throw AuthorizationError.denied }
        return presentation
    }
    func ping() async throws {
        guard !closed, let connection else { throw MCPProcessError.closed }
        _ = try await connection.ping()
    }
    func close() async {
        closed = true
        resourceURIs.removeAll()
        resourceGeneration = UUID()
        let pending = launchTask
        pending?.cancel()
        await gate.close()
        if let pending, case .executed(let opened) = try? await pending.value { await opened.connection.close() }
        await connection?.close()
        connection = nil
        redactor = nil
        repositoryAccess = nil
    }
}
#endif
