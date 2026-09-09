#if os(macOS)
import AgentDeskCore
import Combine
import Foundation

@MainActor
final class ProjectAgentsModel: ObservableObject {
    let project: ProjectRecord
    @Published private(set) var agents: [AgentSnapshot] = []
    @Published private(set) var loading = false
    @Published private(set) var errorMessage: String?
    private let openStore: () async throws -> ProjectAgentStore
    private let openInstructions: () async throws -> ProjectInstructionStore
    private var store: ProjectAgentStore?
    @Published private(set) var instructionStore: ProjectInstructionStore?

    init(project: ProjectRecord, openStore: @escaping () async throws -> ProjectAgentStore,
         openInstructions: @escaping () async throws -> ProjectInstructionStore) {
        self.project = project; self.openStore = openStore; self.openInstructions = openInstructions
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            if store == nil { store = try await openStore() }
            if instructionStore == nil { instructionStore = try await openInstructions() }
            agents = try await store!.agents(in: project.scope, includeArchived: true)
            errorMessage = nil
        } catch is CancellationError {} catch { errorMessage = Self.message(error) }
    }

    func save(_ draft: AgentDraft, replacing existing: AgentSnapshot?) async throws {
        guard let store else { throw AgentConfigurationError.invalidConfiguration }
        if let existing {
            _ = try await store.update(existing.id, in: project.scope,
                                       expectedRevision: existing.definition.revision, draft: draft)
        } else { _ = try await store.create(draft, in: project.scope) }
        await load()
    }

    func toggleArchive(_ existing: AgentSnapshot) async {
        guard let store else { return }
        do {
            _ = try await store.setArchived(!existing.definition.archived, for: existing.id, in: project.scope,
                                            expectedRevision: existing.definition.revision)
            await load()
        } catch { errorMessage = Self.message(error) }
    }

    func preview(_ agent: AgentSnapshot) async -> ComposedInstructions? {
        guard let instructionStore else { return nil }
        do { return try await instructionStore.preview(for: agent, in: project.scope) }
        catch { errorMessage = Self.message(error); return nil }
    }

    static func message(_ error: any Error) -> String {
        if let error = error as? AgentConfigurationError { return error.localizedDescription }
        if let error = error as? CatalogError { return error.localizedDescription }
        if let error = error as? InstructionError { return error.localizedDescription }
        return "AgentDesk couldn’t open or save this agent. Its existing files have been preserved."
    }
}
#endif
