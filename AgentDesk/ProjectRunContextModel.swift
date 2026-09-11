#if os(macOS)
import AgentDeskCore
import AgentDeskSecurity
import AgentDeskRuntime
import Combine
import Foundation

struct RunContextPresentation: Equatable {
    let scope: ProjectScope
    let agentName: String
    let environmentName: String
    let instructions: String
    let sources: String
    let configuration: String

    init(_ context: ProjectRunContext) throws {
        let identity = RedactionContext(scope: context.scope, environmentID: context.configuration.environment.id, runID: RunID())
        let redactor = try ContentRedactor(context: identity)
        func clean(_ text: String) throws -> String { try redactor.redactText(text, in: identity).text }
        scope = context.scope
        agentName = try clean(context.agent.definition.name)
        environmentName = try clean(context.configuration.environment.name)
        instructions = try clean(context.instructions.text)
        sources = try clean(context.instructions.sources.map {
            "\($0.layer) · \($0.title) · version \($0.revision) · \($0.relativeFile)"
        }.joined(separator: "\n"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        configuration = try redactor.redactJSON(String(decoding: encoder.encode(context.configuration), as: UTF8.self), in: identity).text
    }
}

/// Selection and current-context review; execution ownership lives in the separate run session.
@MainActor
final class ProjectRunContextModel: ObservableObject {
    let project: ProjectRecord
    @Published private(set) var agents: [AgentSnapshot] = []
    @Published private(set) var environments: [ProjectEnvironment] = []
    @Published private(set) var presentation: RunContextPresentation?
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    @Published var selectedAgentID: AgentID? { didSet { invalidate() } }
    @Published var selectedEnvironmentID: EnvironmentID? { didSet { invalidate() } }
    private(set) var services: ProjectNativeServices?
    private var context: ProjectRunContext?
    private var generation = 0
    private let open: () async throws -> ProjectNativeServices

    init(project: ProjectRecord, open: @escaping () async throws -> ProjectNativeServices) {
        self.project = project; self.open = open
    }
    func invalidate() { generation += 1; context = nil; presentation = nil; errorMessage = nil }

    func load() async {
        guard !isBusy else { return }
        invalidate(); let token = generation
        isBusy = true; defer { isBusy = false }
        do {
            let services = try await open()
            guard services.setup.scope == project.scope else { throw ExecutionSetupError.scopeMismatch }
            let agents = try await services.catalog.agentStore(in: project.scope).agents(in: project.scope)
            let settings = try await services.setup.settings()
            try Task.checkCancellation()
            guard token == generation else { return }
            self.services = services
            self.agents = agents.filter { $0.definition.enabled }
            environments = settings.project?.draft.environments.filter(\.enabled) ?? []
            if !self.agents.contains(where: { $0.id == selectedAgentID }) { selectedAgentID = nil }
            if !environments.contains(where: { $0.id == selectedEnvironmentID }) { selectedEnvironmentID = nil }
        } catch is CancellationError {} catch { if token == generation { errorMessage = ProjectSetupModel.message(error) } }
    }

    func preview() async {
        guard !isBusy, let services, let selectedAgentID else { return }
        invalidate(); let token = generation
        isBusy = true; defer { isBusy = false }
        do {
            let value = try await services.setup.preview(agentID: selectedAgentID, environmentID: selectedEnvironmentID)
            let presentation = try RunContextPresentation(value)
            try Task.checkCancellation()
            guard token == generation else { return }
            context = value; self.presentation = presentation
        } catch is CancellationError {} catch { if token == generation { errorMessage = ProjectSetupModel.message(error) } }
    }

    func contextForPreparation() async throws -> ProjectRunContext {
        guard !isBusy, let context, let services else { throw ExecutionSetupError.staleContext }
        let token = generation
        do {
            try await services.setup.validate(context)
            guard token == generation else { throw ExecutionSetupError.staleContext }
            return context
        } catch { invalidate(); throw error }
    }

    func mutationHistory() async throws -> (NativeMutationHistory, String) {
        guard !isBusy, let services, let selectedAgentID else { throw ExecutionSetupError.staleContext }
        let token = generation, setup = services.setup
        let current = try await setup.preview(agentID: selectedAgentID, environmentID: selectedEnvironmentID)
        guard token == generation else { throw ExecutionSetupError.staleContext }
        let environment = current.configuration.environment.id
        let scope = project.scope
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment],
            operations: [.readEvidence], expiresAt: Date().addingTimeInterval(1800))
        let service = try NativeMutationHistory(database: services.database, scope: scope, environmentID: environment,
            policy: current.configuration.policy, user: user, currentPolicy: {
                let fresh = try await setup.preview(agentID: selectedAgentID, environmentID: environment).configuration
                guard fresh.scope == scope, fresh.environment.id == environment else { throw AuthorizationError.scopeMismatch }
                return fresh.policy
            })
        return (service, try RunContextPresentation(current).environmentName)
    }

    func archive() async throws -> NativeRunArchive {
        guard !isBusy, let services, let selectedAgentID else { throw ExecutionSetupError.staleContext }
        let token = generation, setup = services.setup
        let current = try await setup.preview(agentID: selectedAgentID, environmentID: selectedEnvironmentID)
        guard token == generation else { throw ExecutionSetupError.staleContext }
        let environment = current.configuration.environment.id
        return try NativeRunArchive(database: services.database, scope: project.scope, agentID: selectedAgentID,
            environmentID: environment, current: {
                try await setup.preview(agentID: selectedAgentID, environmentID: environment).configuration
            })
    }
}
#endif
