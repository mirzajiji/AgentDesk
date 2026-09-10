#if os(macOS)
import AgentDeskCore
import Combine
import Foundation

struct NativeMemoryServices {
    let store: ProjectMemoryStore
    let environments: [ProjectEnvironment]
    let environmentIssue: String?
}
struct MemoryBrowserFilter: Hashable {
    var query = ""
    var kind: MemoryKind?
    var environment: EnvironmentID?
    var includeInactive = false
}

@MainActor
final class ProjectMemoryModel: ObservableObject {
    let project: ProjectRecord
    @Published var filter = MemoryBrowserFilter()
    @Published private(set) var records: [MemoryRecord] = []
    @Published private(set) var history: [MemoryRecord] = []
    @Published private(set) var selectedID: MemoryID?
    @Published var selectedRevision: Int?
    @Published private(set) var services: NativeMemoryServices?
    @Published private(set) var loading = false
    @Published private(set) var selecting = false
    @Published private(set) var more = false
    @Published private(set) var error: String?
    private let open: () async throws -> NativeMemoryServices
    private var generation = 0
    private var selectionGeneration = 0
    private var loadedFilter: MemoryBrowserFilter?
    init(project: ProjectRecord, open: @escaping () async throws -> NativeMemoryServices) {
        self.project = project; self.open = open
    }
    var displayed: MemoryRecord? { history.first { $0.revision == selectedRevision } }
    func load(more: Bool = false) async {
        generation += 1; let token = generation, requested = filter
        let append = more && loadedFilter == requested
        loading = true; error = nil
        if !append { clearSelection() }
        defer { if generation == token { loading = false } }
        do {
            let service: NativeMemoryServices
            if let existing = services { service = existing } else { service = try await open() }
            guard service.store.scope == project.scope else { throw RequirementError.scopeMismatch }
            let page = try await service.store.list(in: project.scope,
                kinds: requested.kind.map { Set([$0]) } ?? Set(MemoryKind.allCases), environment: requested.environment,
                includeInactive: requested.includeInactive, after: append ? records.last?.id : nil, limit: 50, query: requested.query)
            try Task.checkCancellation(); guard token == generation, requested == filter else { return }
            services = service
            records = append ? records + page.filter { item in !records.contains { $0.id == item.id } } : page
            loadedFilter = requested
            self.more = page.count == 50
        } catch is CancellationError {} catch {
            if token == generation { records = []; loadedFilter = nil; self.more = false; clearSelection(); self.error = Self.message(error) }
        }
    }
    func selectFromUI(_ id: MemoryID) {
        let token = beginSelection(id)
        Task { await loadSelection(id, token: token) }
    }
    func select(_ id: MemoryID) async { await loadSelection(id, token: beginSelection(id)) }
    private func beginSelection(_ id: MemoryID) -> Int {
        selectionGeneration += 1; selectedID = id; selectedRevision = nil; history = []; selecting = true
        return selectionGeneration
    }
    private func loadSelection(_ id: MemoryID, token: Int) async {
        guard let services else { if token == selectionGeneration { selecting = false }; return }
        defer { if token == selectionGeneration { selecting = false } }
        do {
            let versions = try await services.store.history(id, in: project.scope)
            guard !versions.isEmpty else { throw ScopedFileError.notFound }
            try Task.checkCancellation(); guard token == selectionGeneration else { return }
            history = versions; selectedRevision = versions.first?.revision; error = nil
        } catch is CancellationError {} catch { if token == selectionGeneration { self.error = Self.message(error) } }
    }
    func didPublish(_ record: MemoryRecord) async {
        guard record.scope == project.scope else { return }
        await load()
        if records.contains(where: { $0.id == record.id }) { await select(record.id) }
    }
    func cancel() {
        generation += 1; clearSelection(); records = []; services = nil; loadedFilter = nil; loading = false; more = false; error = nil
    }
    private func clearSelection() {
        selectionGeneration += 1; selectedID = nil; selectedRevision = nil; history = []; selecting = false
    }
    static func message(_ error: any Error) -> String {
        if error as? RequirementError == .staleVersion { return "This memory changed. Reload it before reviewing a new version." }
        return "Memory could not be opened or validated for this project. Check the search and local storage, then refresh. Existing files are preserved."
    }
}
#endif
