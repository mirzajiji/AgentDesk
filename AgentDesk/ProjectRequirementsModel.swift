#if os(macOS)
import AgentDeskCore
import Combine
import Foundation

struct NativeRequirementServices {
    let store: ProjectRequirementStore
    let environments: [ProjectEnvironment]
    let environmentIssue: String?
}

@MainActor
final class ProjectRequirementsModel: ObservableObject {
    let project: ProjectRecord
    @Published private(set) var records: [RequirementVersion] = []
    @Published private(set) var history: [RequirementVersion] = []
    @Published private(set) var selectedID: RequirementID?
    @Published var selectedVersion: Int?
    @Published private(set) var isLoading = false
    @Published private(set) var isSelecting = false
    @Published private(set) var more = false
    @Published private(set) var errorMessage: String?
    @Published private(set) var services: NativeRequirementServices?
    private let open: () async throws -> NativeRequirementServices
    private var generation = 0
    private var selection = 0

    init(project: ProjectRecord, open: @escaping () async throws -> NativeRequirementServices) {
        self.project = project; self.open = open
    }
    var displayed: RequirementVersion? { history.first { $0.version == selectedVersion } }
    var active: RequirementVersion? {
        let decision = history.first { $0.content.status != .draft }
        return decision?.content.status == .active ? decision : nil
    }
    func load(more: Bool = false) async {
        generation += 1; let token = generation
        isLoading = true; errorMessage = nil
        defer { if generation == token { isLoading = false } }
        do {
            let services: NativeRequirementServices
            if let existing = self.services { services = existing } else { services = try await open() }
            try Task.checkCancellation(); guard token == generation else { return }
            guard services.store.scope == project.scope else { throw RequirementError.scopeMismatch }
            let page = try await services.store.list(in: project.scope, after: more ? records.last?.id : nil, limit: 50)
            try Task.checkCancellation(); guard token == generation else { return }
            self.services = services
            records = more ? records + page.filter { candidate in !records.contains { $0.id == candidate.id } } : page
            self.more = page.count == 50
        } catch is CancellationError {} catch {
            if token == generation {
                records = []; history = []; selection += 1; selectedID = nil; selectedVersion = nil
                isSelecting = false; self.more = false
                errorMessage = Self.message(error)
            }
        }
    }
    // Native List bindings must observe their new selection synchronously.
    func selectFromUI(_ id: RequirementID) {
        guard services != nil else { return }
        let token = beginSelection(id)
        Task { await loadSelection(id, token: token) }
    }
    func select(_ id: RequirementID) async {
        guard services != nil else { return }
        await loadSelection(id, token: beginSelection(id))
    }
    private func beginSelection(_ id: RequirementID) -> Int {
        selection += 1
        selectedID = id; selectedVersion = nil; history = []; isSelecting = true; errorMessage = nil
        return selection
    }
    private func loadSelection(_ id: RequirementID, token: Int) async {
        guard token == selection, let services else { return }
        defer { if token == selection { isSelecting = false } }
        do {
            let history = try await services.store.history(id, in: project.scope)
            guard !history.isEmpty else { throw ScopedFileError.notFound }
            try Task.checkCancellation(); guard token == selection else { return }
            self.history = history; selectedVersion = history.first?.version
        } catch is CancellationError {} catch { if token == selection { errorMessage = Self.message(error) } }
    }
    func didPublish(_ version: RequirementVersion) async {
        guard version.scope == project.scope else { return }
        await load(); await select(version.id)
    }
    func cancel() {
        generation += 1; selection += 1
        isLoading = false; isSelecting = false; services = nil; records = []; history = []
        selectedID = nil; selectedVersion = nil
        errorMessage = nil; more = false
    }
    private static func message(_ error: any Error) -> String {
        if error as? CatalogError == .busy { return RequirementEditorModel.message(error) }
        return "Requirement files could not be opened or validated for this project. Refresh after checking local storage. Existing files have been preserved."
    }
}
#endif
