import Foundation

public enum ExecutionSetupError: Error, Equatable, Sendable {
    case alreadyConfigured, staleContext, scopeMismatch
}

/// Native editor state. Reading it never creates an environment or grants an operation.
public struct ExecutionSetupSnapshot: Equatable, Sendable {
    public let scope: ProjectScope
    public let workspace: ExecutionConfigurationSnapshot?
    public let project: ExecutionConfigurationSnapshot?
    public func configuration(at level: ExecutionConfigurationLevel) -> ExecutionConfigurationSnapshot? {
        level == .workspace ? workspace : project
    }
}

/// Exact source values for the trusted native preparation boundary, not an authorization or wire payload.
/// Source text is untrusted and requires redaction before evidence publication or run-console display.
public struct ProjectRunContext: Equatable, Sendable {
    public let scope: ProjectScope
    public let agent: AgentSnapshot
    public let instructions: ComposedInstructions
    public let configuration: EffectiveExecutionConfiguration
    let selectedEnvironmentID: EnvironmentID?
    let runOverrides: ExecutionSettings?
}

/// Local administrative service. Keep this interface out of model tools and mobile requests.
/// Settings saves use the existing immutable version/CAS store. The native owner must propagate policy
/// changes to an active run service or await its shutdown before replacing execution configuration.
public actor ProjectExecutionSetupService {
    public nonisolated let scope: ProjectScope
    private let catalog: WorkspaceCatalog
    public init(catalog: WorkspaceCatalog, scope: ProjectScope) { self.catalog = catalog; self.scope = scope }

    public func settings() async throws -> ExecutionSetupSnapshot {
        try await catalog.executionConfigurationStore(in: scope).setup(in: scope)
    }
    public func save(_ draft: ExecutionConfigurationDraft, at level: ExecutionConfigurationLevel,
                     expectedRevision: Int?) async throws -> ExecutionConfigurationSnapshot {
        try await catalog.executionConfigurationStore(in: scope).save(draft, at: level, in: scope, expectedRevision: expectedRevision)
    }

    /// Returns an editable proposal only for a missing document. The caller must display it and explicitly save.
    /// A new project proposal creates one local development environment; no existing policies are filled in.
    public func proposedDefaults(at level: ExecutionConfigurationLevel) async throws -> ExecutionConfigurationDraft {
        guard try await settings().configuration(at: level) == nil else { throw ExecutionSetupError.alreadyConfigured }
        let rules = [PolicyRule(.readEvidence, .allow), PolicyRule(.runReadOnlyAgent, .approval)]
        let policy = try PolicyDocument(level: level == .workspace ? .workspace : .project,
            workspaceID: scope.workspaceID, projectID: level == .workspace ? nil : scope.projectID, rules: rules)
        let settings = ExecutionSettings(maximumSteps: 30, timeoutSeconds: 600, maximumOutputBytes: 65_536, accessCeiling: .readOnly)
        if level == .workspace { return ExecutionConfigurationDraft(settings: settings, policy: policy) }
        let environmentID = EnvironmentID()
        let environment = ProjectEnvironment(id: environmentID, scope: scope, name: "Development", kind: .development,
            constraints: .init(accessCeiling: .readOnly), policy: try PolicyDocument(level: .environment,
                workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environmentID, rules: rules))
        return ExecutionConfigurationDraft(settings: settings, environments: [environment], defaultEnvironmentID: environmentID, policy: policy)
    }

    /// Resolve current sources twice across store suspension points. A changing source fails visibly;
    /// there is no unbounded retry or silent use of a mixed agent/configuration/instruction revision.
    public func preview(agentID: AgentID, environmentID: EnvironmentID? = nil,
                        run: ExecutionSettings? = nil) async throws -> ProjectRunContext {
        let first = try await observe(agentID: agentID, environmentID: environmentID, run: run)
        let second = try await observe(agentID: agentID, environmentID: environmentID, run: run)
        guard first == second else { throw ExecutionSetupError.staleContext }
        return first
    }

    /// Call immediately before native run preparation. Later edits do not rewrite this frozen context;
    /// runtime policy checks still run at dispatch and throughout execution.
    public func validate(_ context: ProjectRunContext) async throws {
        guard context.scope == scope else { throw ExecutionSetupError.scopeMismatch }
        let current = try await preview(agentID: context.agent.id, environmentID: context.selectedEnvironmentID, run: context.runOverrides)
        guard current == context else { throw ExecutionSetupError.staleContext }
    }

    private func observe(agentID: AgentID, environmentID: EnvironmentID?, run: ExecutionSettings?) async throws -> ProjectRunContext {
        try Task.checkCancellation()
        let agents = try await catalog.agentStore(in: scope), agent = try await agents.agent(agentID, in: scope)
        let settings = try await catalog.executionConfigurationStore(in: scope)
        let instructions = try await catalog.instructionStore(in: scope).preview(for: agent, in: scope)
        let configuration = try await settings.preview(for: agent, in: scope, environmentID: environmentID, run: run)
        try Task.checkCancellation()
        return ProjectRunContext(scope: scope, agent: agent, instructions: instructions, configuration: configuration,
            selectedEnvironmentID: environmentID, runOverrides: run)
    }
}
