#if os(macOS)
import AgentDeskCore
import Combine
import Foundation

@MainActor
final class ProjectSkillsModel: ObservableObject {
    let scope: ProjectScope
    let store: ProjectSkillStore
    @Published private(set) var skills: [SkillSnapshot] = []
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    init(scope: ProjectScope, store: ProjectSkillStore) { self.scope = scope; self.store = store }
    func load() async {
        loading = true; defer { loading = false }
        do {
            let shared = try await store.skills(at: SkillScope(workspaceID: scope.workspaceID), in: scope, includeArchived: true)
            let local = try await store.skills(at: SkillScope(workspaceID: scope.workspaceID, projectID: scope.projectID), in: scope, includeArchived: true)
            skills = shared + local; error = nil
        } catch is CancellationError {} catch { skills = []; self.error = ProjectAgentsModel.message(error) }
    }
    func save(_ draft: SkillDraft, owner: SkillScope, replacing: SkillSnapshot?) async throws {
        _ = try await store.save(draft, at: owner, in: scope, id: replacing?.id, expectedRevision: replacing?.definition.revision)
        await load()
    }
    func archive(_ skill: SkillSnapshot) async {
        do {
            _ = try await store.setArchived(!skill.definition.archived, for: skill.id, at: skill.definition.scope, in: scope, expectedRevision: skill.definition.revision)
            await load()
        } catch { self.error = ProjectAgentsModel.message(error) }
    }
}
#endif
