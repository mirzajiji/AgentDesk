#if os(macOS)
import AgentDeskCore
import Combine
import Foundation

@MainActor
final class SharedInstructionsModel: ObservableObject {
    @Published var level: InstructionLevel = .project
    @Published var draft = InstructionBundleDraft()
    @Published var selectedID: InstructionID?
    @Published private(set) var revision: Int?
    @Published private(set) var busy = true
    @Published private(set) var errorMessage: String?
    private let store: ProjectInstructionStore
    private let scope: ProjectScope
    private var generation = 0
    private var loadedLevel: InstructionLevel?
    private var baseline = InstructionBundleDraft()
    var canEdit: Bool { loadedLevel == level && !busy }
    var hasUnsavedChanges: Bool { draft != baseline }

    init(store: ProjectInstructionStore, scope: ProjectScope) { self.store = store; self.scope = scope }

    func reload() async {
        generation += 1
        let current = generation, requestedLevel = level
        busy = true; errorMessage = nil; loadedLevel = nil
        draft = InstructionBundleDraft(); baseline = draft; revision = nil; selectedID = nil
        defer { if generation == current { busy = false } }
        do {
            let saved = try await store.bundle(at: requestedLevel, in: scope)
            try Task.checkCancellation()
            guard generation == current, level == requestedLevel else { return }
            draft = saved?.draft ?? InstructionBundleDraft(); revision = saved?.revision
            baseline = draft; loadedLevel = requestedLevel
            selectedID = draft.documents.first?.id
        } catch is CancellationError {} catch {
            guard generation == current, level == requestedLevel else { return }
            errorMessage = ProjectAgentsModel.message(error)
        }
    }

    func add() {
        guard canEdit else { return }
        let document = InstructionDocument(title: "New Instruction", text: "Describe the shared guidance for this scope.")
        draft.documents.append(document); draft.roots.append(document.id); selectedID = document.id
    }

    func removeSelected() {
        guard let selectedID else { return }
        guard !draft.documents.contains(where: { $0.includes.contains(selectedID) }) else {
            errorMessage = "Remove references to this instruction before deleting it."; return
        }
        self.selectedID = nil
        draft.documents.removeAll { $0.id == selectedID }; draft.roots.removeAll { $0 == selectedID }
        self.selectedID = draft.documents.first?.id
    }

    func setRoot(_ id: InstructionID, enabled: Bool) {
        draft.roots.removeAll { $0 == id }
        if enabled { draft.roots.append(id) }
    }

    func setIncluded(_ id: InstructionID, in document: InstructionID, enabled: Bool) {
        guard let index = draft.documents.firstIndex(where: { $0.id == document }) else { return }
        draft.documents[index].includes.removeAll { $0 == id }
        if enabled { draft.documents[index].includes.append(id) }
    }

    func save() async -> Bool {
        guard canEdit else { return false }
        busy = true; errorMessage = nil
        defer { busy = false }
        do {
            let saved = try await store.save(draft, at: level, in: scope, expectedRevision: revision)
            draft = saved.draft; revision = saved.revision
            baseline = draft
            return true
        } catch { errorMessage = ProjectAgentsModel.message(error); return false }
    }
}
#endif
