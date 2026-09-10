import Foundation

public enum ExecutionConfigurationError: Error, Equatable, Sendable {
    case invalidConfiguration, scopeMismatch, staleRevision, disabledAgent, unavailableEnvironment
    case environmentDenied, modelDenied, accessDenied, conflictingOutputSchema
}

/// Nil inherits. Limits are ceilings; arrays are allowlists (nil unrestricted, empty denies all).
public struct ExecutionSettings: Codable, Equatable, Sendable {
    public var modelIdentifier: String?
    public var maximumSteps: Int?
    public var timeoutSeconds: Int?
    public var maximumOutputBytes: Int?
    public var allowedModelIdentifiers: [String]?
    public var allowedEnvironmentIDs: [EnvironmentID]?
    public var accessCeiling: CodexAgentProfile.Access?
    public var outputSchema: OutputSchema?

    public init(modelIdentifier: String? = nil, maximumSteps: Int? = nil, timeoutSeconds: Int? = nil,
                maximumOutputBytes: Int? = nil, allowedModelIdentifiers: [String]? = nil,
                allowedEnvironmentIDs: [EnvironmentID]? = nil, accessCeiling: CodexAgentProfile.Access? = nil,
                outputSchema: OutputSchema? = nil) {
        self.modelIdentifier = modelIdentifier; self.maximumSteps = maximumSteps; self.timeoutSeconds = timeoutSeconds
        self.maximumOutputBytes = maximumOutputBytes; self.allowedModelIdentifiers = allowedModelIdentifiers
        self.allowedEnvironmentIDs = allowedEnvironmentIDs; self.accessCeiling = accessCeiling; self.outputSchema = outputSchema
    }
    private enum CodingKeys: String, CodingKey, CaseIterable {
        case modelIdentifier, maximumSteps, timeoutSeconds, maximumOutputBytes, allowedModelIdentifiers, allowedEnvironmentIDs, accessCeiling, outputSchema
    }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownConfigurationKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelIdentifier = try c.decodeIfPresent(String.self, forKey: .modelIdentifier)
        maximumSteps = try c.decodeIfPresent(Int.self, forKey: .maximumSteps)
        timeoutSeconds = try c.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
        maximumOutputBytes = try c.decodeIfPresent(Int.self, forKey: .maximumOutputBytes)
        allowedModelIdentifiers = try c.decodeIfPresent([String].self, forKey: .allowedModelIdentifiers)
        allowedEnvironmentIDs = try c.decodeIfPresent([EnvironmentID].self, forKey: .allowedEnvironmentIDs)
        accessCeiling = try c.decodeIfPresent(CodexAgentProfile.Access.self, forKey: .accessCeiling)
        outputSchema = try c.decodeIfPresent(OutputSchema.self, forKey: .outputSchema)
        try validate()
    }
    public func validate() throws {
        guard maximumSteps.map({ (1...1_000).contains($0) }) ?? true,
              timeoutSeconds.map({ (1...86_400).contains($0) }) ?? true,
              maximumOutputBytes.map({ (1...262_144).contains($0) }) ?? true else { throw ExecutionConfigurationError.invalidConfiguration }
        if let modelIdentifier { try Self.validateModel(modelIdentifier) }
        if let models = allowedModelIdentifiers {
            guard models.count <= 64, Set(models).count == models.count else { throw ExecutionConfigurationError.invalidConfiguration }
            for model in models { try Self.validateModel(model) }
        }
        if let environments = allowedEnvironmentIDs {
            guard environments.count <= 64, Set(environments).count == environments.count else { throw ExecutionConfigurationError.invalidConfiguration }
        }
        if let outputSchema {
            guard case .object = outputSchema else { throw OutputContractError.invalidSchema }
            _ = try outputSchema.jsonData()
        }
    }
    static func validateModel(_ model: String) throws {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
        guard !model.isEmpty, model.utf8.count <= 128, model.unicodeScalars.allSatisfy(allowed.contains) else {
            throw ExecutionConfigurationError.invalidConfiguration
        }
    }
}

public struct ProjectEnvironment: Codable, Equatable, Sendable, Identifiable {
    public let id: EnvironmentID
    public let scope: ProjectScope
    public var name: String
    public var kind: PolicySnapshot.Environment
    public var enabled: Bool
    public var constraints: ExecutionSettings
    public var policy: PolicyDocument?
    public init(id: EnvironmentID = EnvironmentID(), scope: ProjectScope, name: String,
                kind: PolicySnapshot.Environment = .development, enabled: Bool = true, constraints: ExecutionSettings = .init(), policy: PolicyDocument? = nil) {
        self.id = id; self.scope = scope; self.name = name; self.kind = kind; self.enabled = enabled; self.constraints = constraints; self.policy = policy
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case id, scope, name, kind, enabled, constraints, policy }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownConfigurationKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(EnvironmentID.self, forKey: .id); scope = try c.decode(ProjectScope.self, forKey: .scope)
        name = try c.decode(String.self, forKey: .name); kind = try c.decode(PolicySnapshot.Environment.self, forKey: .kind)
        enabled = try c.decode(Bool.self, forKey: .enabled); constraints = try c.decode(ExecutionSettings.self, forKey: .constraints)
        policy = try c.decodeIfPresent(PolicyDocument.self, forKey: .policy)
        try validate(in: scope)
    }
    public func validate(in scope: ProjectScope) throws {
        guard self.scope == scope else { throw ExecutionConfigurationError.scopeMismatch }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 100,
              !name.contains("/"), !name.contains("\\"), !name.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw ExecutionConfigurationError.invalidConfiguration
        }
        try constraints.validate()
        if let policy {
            try policy.validate()
            guard policy.level == .environment, policy.workspaceID == scope.workspaceID,
                  policy.projectID == scope.projectID, policy.environmentID == id else { throw ExecutionConfigurationError.scopeMismatch }
        }
    }
}
public enum ExecutionConfigurationLevel: String, Codable, Sendable { case workspace, project }
public struct ExecutionConfigurationDraft: Codable, Equatable, Sendable {
    public var settings: ExecutionSettings
    public var environments: [ProjectEnvironment]
    public var defaultEnvironmentID: EnvironmentID?
    public var policy: PolicyDocument?
    public var workspaceLocked: Bool
    public init(settings: ExecutionSettings = .init(), environments: [ProjectEnvironment] = [], defaultEnvironmentID: EnvironmentID? = nil,
                policy: PolicyDocument? = nil, workspaceLocked: Bool = false) {
        self.settings = settings; self.environments = environments; self.defaultEnvironmentID = defaultEnvironmentID
        self.policy = policy; self.workspaceLocked = workspaceLocked
    }
    private enum CodingKeys: String, CodingKey, CaseIterable { case settings, environments, defaultEnvironmentID, policy, workspaceLocked }
    public init(from decoder: any Decoder) throws {
        try rejectUnknownConfigurationKeys(decoder, allowed: Set(CodingKeys.allCases.map(\.rawValue)))
        let c = try decoder.container(keyedBy: CodingKeys.self)
        settings = try c.decode(ExecutionSettings.self, forKey: .settings)
        environments = try c.decode([ProjectEnvironment].self, forKey: .environments)
        defaultEnvironmentID = try c.decodeIfPresent(EnvironmentID.self, forKey: .defaultEnvironmentID)
        policy = try c.decodeIfPresent(PolicyDocument.self, forKey: .policy)
        workspaceLocked = try c.decodeIfPresent(Bool.self, forKey: .workspaceLocked) ?? false
    }
    public func validate(at level: ExecutionConfigurationLevel, in scope: ProjectScope) throws {
        try settings.validate()
        guard level == .workspace || !workspaceLocked else { throw ExecutionConfigurationError.invalidConfiguration }
        if let policy {
            try policy.validate()
            guard policy.level == (level == .workspace ? .workspace : .project), policy.workspaceID == scope.workspaceID,
                  policy.projectID == (level == .workspace ? nil : scope.projectID) else { throw ExecutionConfigurationError.scopeMismatch }
        }
        guard environments.count <= 64, Set(environments.map(\.id)).count == environments.count,
              Set(environments.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }).count == environments.count else {
            throw ExecutionConfigurationError.invalidConfiguration
        }
        guard level == .project || (environments.isEmpty && defaultEnvironmentID == nil) else { throw ExecutionConfigurationError.invalidConfiguration }
        for environment in environments { try environment.validate(in: scope) }
        if let selected = defaultEnvironmentID {
            guard environments.contains(where: { $0.id == selected && $0.enabled }) else { throw ExecutionConfigurationError.unavailableEnvironment }
        }
    }
}
public struct ExecutionConfigurationSnapshot: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let workspaceID: WorkspaceID
    public let projectID: ProjectID?
    public let revision: Int
    public let createdAt: Date
    public let draft: ExecutionConfigurationDraft
}
public enum ExecutionLayer: String, Codable, Sendable { case global, workspace, project, environment, agent, workflow, run }
public struct ExecutionConfigurationSource: Codable, Equatable, Sendable {
    public let layer: ExecutionLayer
    /// Nil for transient workflow/run overrides; persisted sources carry exact revisions.
    public let revision: Int?
    public let settings: ExecutionSettings
    public let fingerprint: ActionFingerprint
}
/// Frozen, validated preview. This is configuration, not an execution grant.
public struct EffectiveExecutionConfiguration: Encodable, Equatable, Sendable {
    public let scope: ProjectScope
    public let agentID: AgentID
    public let agentRevision: Int
    public let environment: ProjectEnvironment
    public let policy: PolicySnapshot
    public let modelIdentifier: String?
    public let requestedAccess: CodexAgentProfile.Access
    public let maximumSteps: Int
    public let timeoutSeconds: Int
    public let maximumOutputBytes: Int
    public let outputSchema: OutputSchema?
    public let knowledge: AgentKnowledgeSelection?
    public let sources: [ExecutionConfigurationSource]
    /// Winning scalar or limiting budget source. All allowlist constraints remain visible in sources.
    public let origins: [String: ExecutionLayer]
    public var fingerprint: ActionFingerprint { get throws { try .canonical(self) } }
}

public enum ExecutionConfigurationComposer {
    public static func compose(scope: ProjectScope, agent: AgentSnapshot,
                               workspace: ExecutionConfigurationSnapshot?, project: ExecutionConfigurationSnapshot?,
                               environmentID: EnvironmentID? = nil, workflow: ExecutionSettings? = nil,
                               run: ExecutionSettings? = nil) throws -> EffectiveExecutionConfiguration {
        guard agent.definition.scope == scope else { throw ExecutionConfigurationError.scopeMismatch }
        guard agent.definition.enabled, !agent.definition.archived else { throw ExecutionConfigurationError.disabledAgent }
        try agent.definition.profile.validate()
        for (level, snapshot) in [(ExecutionConfigurationLevel.workspace, workspace), (.project, project)] {
            if let snapshot {
                guard snapshot.schemaVersion == 1, snapshot.workspaceID == scope.workspaceID,
                      snapshot.projectID == (level == .project ? scope.projectID : nil),
                      (1...1_000_000).contains(snapshot.revision), snapshot.createdAt.timeIntervalSince1970.isFinite else { throw ExecutionConfigurationError.scopeMismatch }
                try snapshot.draft.validate(at: level, in: scope)
            }
        }
        guard let selected = environmentID ?? project?.draft.defaultEnvironmentID,
              let environment = project?.draft.environments.first(where: { $0.id == selected && $0.enabled }) else { throw ExecutionConfigurationError.unavailableEnvironment }
        let profile = agent.definition.profile
        let layers: [(ExecutionLayer, Int?, ExecutionSettings?)] = [
            (.global, 1, ExecutionSettings(maximumSteps: 1_000, timeoutSeconds: 3_600, maximumOutputBytes: 262_144)),
            (.workspace, workspace?.revision, workspace?.draft.settings), (.project, project?.revision, project?.draft.settings),
            (.environment, project?.revision, environment.constraints),
            (.agent, agent.definition.revision, ExecutionSettings(modelIdentifier: profile.modelIdentifier, maximumSteps: profile.maximumSteps,
                timeoutSeconds: profile.timeoutSeconds, maximumOutputBytes: profile.maximumOutputBytes,
                allowedEnvironmentIDs: profile.allowedEnvironmentIDs, outputSchema: profile.outputSchema)),
            (.workflow, nil, workflow), (.run, nil, run)
        ]
        var model: String?, schema: OutputSchema?, models: Set<String>?
        var steps = Int.max, timeout = Int.max, bytes = Int.max
        var sources: [ExecutionConfigurationSource] = [], origins: [String: ExecutionLayer] = [:]
        for (layer, revision, settings) in layers {
            guard let settings else { continue }
            try settings.validate()
            if let allowed = settings.allowedEnvironmentIDs, !allowed.contains(selected) { throw ExecutionConfigurationError.environmentDenied }
            if let allowed = settings.allowedModelIdentifiers { models = models.map { $0.intersection(allowed) } ?? Set(allowed) }
            if settings.accessCeiling == .readOnly, profile.requestedAccess == .workspaceWrite { throw ExecutionConfigurationError.accessDenied }
            if let value = settings.modelIdentifier { model = value; origins["modelIdentifier"] = layer }
            if let value = settings.maximumSteps, value < steps { steps = value; origins["maximumSteps"] = layer }
            if let value = settings.timeoutSeconds, value < timeout { timeout = value; origins["timeoutSeconds"] = layer }
            if let value = settings.maximumOutputBytes, value < bytes { bytes = value; origins["maximumOutputBytes"] = layer }
            if let value = settings.outputSchema {
                guard schema == nil || schema == value else { throw ExecutionConfigurationError.conflictingOutputSchema }
                if schema == nil { schema = value; origins["outputSchema"] = layer }
            }
            sources.append(ExecutionConfigurationSource(layer: layer, revision: revision, settings: settings,
                                                        fingerprint: try ActionFingerprint.canonical(settings)))
        }
        if let models { guard let model, models.contains(model) else { throw ExecutionConfigurationError.modelDenied } }
        // Omitted policies deny every operation, with a stable version for this bundled default.
        func denyDefault(_ level: PolicyLevel) throws -> PolicyDocument {
            try PolicyDocument(revision: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, level: level,
                workspaceID: scope.workspaceID, projectID: level == .workspace ? nil : scope.projectID,
                environmentID: level == .environment ? environment.id : nil, rules: [])
        }
        let policy = try PolicySnapshot(workspace: workspace?.draft.policy ?? denyDefault(.workspace),
            project: project?.draft.policy ?? denyDefault(.project), environment: environment.policy ?? denyDefault(.environment),
            environmentKind: environment.kind, workspaceLocked: workspace?.draft.workspaceLocked ?? false)
        return EffectiveExecutionConfiguration(scope: scope, agentID: agent.id, agentRevision: agent.definition.revision,
            environment: environment, policy: policy, modelIdentifier: model, requestedAccess: profile.requestedAccess,
            maximumSteps: steps, timeoutSeconds: timeout, maximumOutputBytes: bytes, outputSchema: schema, knowledge: profile.knowledge, sources: sources, origins: origins)
    }
}

private struct ConfigurationKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
func rejectUnknownConfigurationKeys(_ decoder: any Decoder, allowed: Set<String>) throws {
    let values = try decoder.container(keyedBy: ConfigurationKey.self)
    guard Set(values.allKeys.map(\.stringValue)).isSubset(of: allowed) else { throw ExecutionConfigurationError.invalidConfiguration }
}
