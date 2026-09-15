#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

enum MCPDiscoveryKind: Sendable { case tools, prompts, resources, resourceTemplates }

/// Trusted Mac host boundary. Resource resolution must validate physical project/executable identity.
/// Neither configuration nor the resource fingerprint is itself launch authority.
actor MCPLaunchPolicySession {
    private let configuration: MCPStdioConfiguration
    private let gate: PolicyGate
    private let action: PolicyAction
    private let credentialAction: PolicyAction
    private let discoveryAction: PolicyAction
    private let promptDiscoveryAction: PolicyAction
    private let templateDiscoveryAction: PolicyAction
    private let resourceDiscoveryAction: PolicyAction
    private var resourceReadActionIDs: [String: UUID] = [:]
    private let requesterID: UUID
    private let policyFingerprint: ActionFingerprint
    private let validate: @Sendable () async throws -> (PolicyAction, PolicySnapshot)
    private var closed = false

    private struct DiscoveryPayload: Encodable {
        let configuration: ActionFingerprint
        let method: String
    }
    private init(configuration: MCPStdioConfiguration, action: PolicyAction, policy: PolicySnapshot, authorities: [PolicyAuthority], requesterID: UUID,
                 approvals: ApprovalStore, validate: @escaping @Sendable () async throws -> (PolicyAction, PolicySnapshot)) throws {
        guard let requester = authorities.first(where: { $0.id == requesterID }), case .localUser = requester.kind else {
            throw AuthorizationError.denied
        }
        credentialAction = try PolicyAction(scope: action.scope, environmentID: action.environmentID, operation: .readSecret,
            resource: action.resource, payload: action.payload)
        // Bind this review to listing tools, not arbitrary MCP requests or the launch itself.
        discoveryAction = try PolicyAction(scope: action.scope, environmentID: action.environmentID, operation: .readEvidence,
            resource: action.resource, payload: ActionFingerprint.canonical(DiscoveryPayload(configuration: action.payload, method: "tools/list")))
        promptDiscoveryAction = try PolicyAction(scope: action.scope, environmentID: action.environmentID, operation: .readEvidence,
            resource: action.resource, payload: ActionFingerprint.canonical(DiscoveryPayload(configuration: action.payload, method: "prompts/list")))
        resourceDiscoveryAction = try PolicyAction(scope: action.scope, environmentID: action.environmentID, operation: .readEvidence,
            resource: action.resource, payload: ActionFingerprint.canonical(DiscoveryPayload(configuration: action.payload, method: "resources/list")))
        templateDiscoveryAction = try PolicyAction(scope: action.scope, environmentID: action.environmentID, operation: .readEvidence,
            resource: action.resource, payload: ActionFingerprint.canonical(DiscoveryPayload(configuration: action.payload, method: "resources/templates/list")))
        self.configuration = configuration
        self.action = action; self.requesterID = requesterID; self.validate = validate
        policyFingerprint = try policy.fingerprint
        gate = try PolicyGate(policy: policy, authorities: authorities, store: approvals)
    }

    static func open(configurations: ProjectMCPConfigurationStore<MCPStdioConfiguration>, connectionID: UUID,
                     scope: ProjectScope, environmentID: EnvironmentID, authorities: [PolicyAuthority], requesterID: UUID,
                     approvals: ApprovalStore, currentPolicy: @escaping @Sendable () async throws -> PolicySnapshot,
                     resolveResource: @escaping @Sendable (MCPStdioConfiguration) async throws -> ActionFingerprint) async throws -> MCPLaunchPolicySession {
        guard let requester = authorities.first(where: { $0.id == requesterID }), case .localUser = requester.kind else {
            throw AuthorizationError.denied
        }
        let actionID = UUID()
        let validate: @Sendable () async throws -> (PolicyAction, PolicySnapshot) = {
            try Task.checkCancellation()
            guard let record = try await configurations.read(id: connectionID, in: scope),
                  record.configuration.enabled, record.configuration.environmentID == environmentID else {
                throw AuthorizationError.denied
            }
            let resource = try await resolveResource(record.configuration)
            let payload = try ActionFingerprint.canonical(record)
            let action = try PolicyAction(id: actionID, scope: scope, environmentID: environmentID,
                operation: .runShell, resource: resource, payload: payload)
            let policy = try await currentPolicy()
            guard policy.scope == scope, policy.environmentID == environmentID else { throw AuthorizationError.scopeMismatch }
            return (action, policy)
        }
        let (action, policy) = try await validate()
        guard let record = try await configurations.read(id: connectionID, in: scope),
              try ActionFingerprint.canonical(record) == action.payload else { throw AuthorizationError.stalePolicy }
        return try Self(configuration: record.configuration, action: action, policy: policy, authorities: authorities, requesterID: requesterID,
            approvals: approvals, validate: validate)
    }
    private func check() async throws {
        guard !closed else { throw AuthorizationError.denied }
        let (current, policy) = try await validate()
        try Task.checkCancellation()
        guard !closed else { throw AuthorizationError.denied }
        guard current == action, try policy.fingerprint == policyFingerprint else { throw AuthorizationError.stalePolicy }
    }
    func prepare() async throws -> PolicyPreparation {
        try await check()
        return try await gate.prepare(action, requesterID: requesterID)
    }
    func review(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        try await check()
        return try await gate.review(id, expectedAction: action, requesterID: requesterID, reviewerID: requesterID,
            approve: approve, expectedSequence: expectedSequence)
    }
    func execute<Value: Sendable>(approvalID: UUID? = nil,
                                 launch: @Sendable () async throws -> Value) async throws -> PolicyExecutionResult<Value> {
        try await check()
        return try await gate.execute(action, requesterID: requesterID, approvalID: approvalID) { _ in
            try await self.check()
            return try await launch()
        }
    }
    private func discoveryAction(for kind: MCPDiscoveryKind) -> PolicyAction {
        switch kind {
        case .tools: discoveryAction
        case .prompts: promptDiscoveryAction
        case .resources: resourceDiscoveryAction
        case .resourceTemplates: templateDiscoveryAction
        }
    }
    func prepareDiscovery(kind: MCPDiscoveryKind = .tools) async throws -> PolicyPreparation {
        try await check()
        return try await gate.prepare(discoveryAction(for: kind), requesterID: requesterID)
    }
    func reviewDiscovery(_ id: UUID, approve: Bool, expectedSequence: Int64, kind: MCPDiscoveryKind = .tools) async throws -> ApprovalRecord {
        try await check()
        return try await gate.review(id, expectedAction: discoveryAction(for: kind), requesterID: requesterID, reviewerID: requesterID,
            approve: approve, expectedSequence: expectedSequence)
    }
    func discover<Value: Sendable>(approvalID: UUID? = nil, kind: MCPDiscoveryKind = .tools,
                                  read: @Sendable () async throws -> Value) async throws -> PolicyExecutionResult<Value> {
        try await check()
        return try await gate.execute(discoveryAction(for: kind), requesterID: requesterID, approvalID: approvalID) { _ in
            try await self.check()
            let value = try await read()
            // A configuration/policy change during the traversal invalidates the returned claims.
            try await self.check()
            return value
        }
    }
    private struct ResourceReadPayload: Encodable {
        let configuration: ActionFingerprint
        let method = "resources/read"
        let uri: String
    }
    private func resourceReadAction(uri: String, renew: Bool = false) throws -> PolicyAction {
        // Reuse the wire validator without normalizing opaque server resource identities.
        _ = try MCPResourceRead.parameters(mode: .legacy, uri: uri)
        guard resourceReadActionIDs[uri] != nil || resourceReadActionIDs.count < 256 else { throw AuthorizationError.invalidInput }
        if renew || resourceReadActionIDs[uri] == nil { resourceReadActionIDs[uri] = UUID() }
        guard let id = resourceReadActionIDs[uri] else { throw AuthorizationError.invalidInput }
        return try PolicyAction(id: id, scope: action.scope, environmentID: action.environmentID,
            operation: .readEvidence, resource: action.resource,
            payload: ActionFingerprint.canonical(ResourceReadPayload(configuration: action.payload, uri: uri)))
    }
    func prepareResourceRead(uri: String) async throws -> PolicyPreparation {
        try await check()
        return try await gate.prepare(resourceReadAction(uri: uri, renew: true), requesterID: requesterID)
    }
    func reviewResourceRead(_ id: UUID, uri: String, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        try await check()
        return try await gate.review(id, expectedAction: resourceReadAction(uri: uri), requesterID: requesterID,
            reviewerID: requesterID, approve: approve, expectedSequence: expectedSequence)
    }
    func readResource<Value: Sendable>(uri: String, approvalID: UUID? = nil,
                                      read: @Sendable () async throws -> Value) async throws -> PolicyExecutionResult<Value> {
        try await check()
        return try await gate.execute(resourceReadAction(uri: uri), requesterID: requesterID, approvalID: approvalID) { _ in
            try await self.check()
            let value = try await read()
            try await self.check()
            return value
        }
    }
    func prepareCredentials() async throws -> PolicyPreparation {
        try await check()
        guard !configuration.secretEnvironment.isEmpty else { throw AuthorizationError.invalidInput }
        return try await gate.prepare(credentialAction, requesterID: requesterID)
    }
    func reviewCredentials(_ id: UUID, approve: Bool, expectedSequence: Int64) async throws -> ApprovalRecord {
        try await check()
        return try await gate.review(id, expectedAction: credentialAction, requesterID: requesterID, reviewerID: requesterID,
            approve: approve, expectedSequence: expectedSequence)
    }
    /// Used only inside an approved launch. Credential reads still cross their own policy boundary.
    func environment(store: any SecretStore, approvalID: UUID? = nil) async throws -> [String: String] {
        try await check()
        guard configuration.scope == action.scope, configuration.environmentID == action.environmentID,
              store.scope.workspaceID == action.scope.workspaceID, store.scope.projectID == action.scope.projectID,
              store.scope.environmentID == action.environmentID else { throw AuthorizationError.scopeMismatch }
        let configuration = configuration
        let result = try await gate.execute(credentialAction, requesterID: requesterID, approvalID: approvalID) { _ in
            try await self.check()
            var values: [String: String] = [:]
            var bytes = 0
            for (name, reference) in configuration.secretEnvironment.sorted(by: { $0.key < $1.key }) {
                try Task.checkCancellation()
                guard let secret = try await store.get(reference) else { throw SecretStoreError.invalidValue }
                let value = try secret.withBytes { data -> String in
                    guard let text = String(data: data, encoding: .utf8), !text.utf8.contains(0) else { throw SecretStoreError.invalidValue }
                    return text
                }
                bytes += name.utf8.count + value.utf8.count
                guard bytes <= 65_536 else { throw SecretStoreError.invalidValue }
                values[name] = value
            }
            try await self.check()
            return values
        }
        guard case .executed(let values) = result else { throw AuthorizationError.denied }
        return values
    }
    func close() async { closed = true; resourceReadActionIDs.removeAll(); await gate.removeAuthority(requesterID) }
}
#endif
