#if os(macOS)
import AgentDeskCore
import Combine
import Foundation

struct NativeBugServices {
    let store: ProjectBugStore
    let environments: [ProjectEnvironment]
    let environmentIssue: String?
}
struct BugBrowserFilter: Hashable {
    var query = ""
    var status: BugStatus?
    var environment: EnvironmentID?
    var registered: Bool?
    var includeArchived = false
}

@MainActor
final class ProjectBugsModel: ObservableObject {
    let project: ProjectRecord
    @Published var filter = BugBrowserFilter()
    @Published private(set) var services: NativeBugServices?
    @Published private(set) var records: [BugRecord] = []
    @Published private(set) var history: [BugRecord] = []
    @Published private(set) var incoming: [BugRecord] = []
    @Published private(set) var selectedID: BugID?
    @Published var selectedRevision: Int?
    @Published private(set) var loading = false
    @Published private(set) var selecting = false
    @Published private(set) var more = false
    @Published private(set) var moreIncoming = false
    @Published private(set) var loadingIncoming = false
    @Published private(set) var error: String?
    private let open: () async throws -> NativeBugServices
    private var generation = 0, selectionGeneration = 0
    private var loadedFilter: BugBrowserFilter?
    var displayed: BugRecord? { history.first { $0.revision == selectedRevision } }
    init(project: ProjectRecord, open: @escaping () async throws -> NativeBugServices) { self.project = project; self.open = open }

    func load(more: Bool = false) async {
        generation += 1; let token = generation, requested = filter
        let append = more && loadedFilter == requested
        loading = true; error = nil
        if !append { clearSelection() }
        defer { if token == generation { loading = false } }
        do {
            let service: NativeBugServices
            if let existing = services { service = existing } else { service = try await open() }
            guard service.store.scope == project.scope else { throw BugRegistryError.scopeMismatch }
            let statuses = requested.status.map { Set([$0]) } ?? Set(BugStatus.allCases.filter { requested.includeArchived || $0 != .archived })
            let page = try await service.store.list(in: project.scope, statuses: statuses, environment: requested.environment,
                registered: requested.registered, after: append ? records.last?.id : nil, limit: 50, query: requested.query)
            try Task.checkCancellation(); guard token == generation, requested == filter else { return }
            services = service; loadedFilter = requested
            records = append ? records + page.filter { value in !records.contains { $0.id == value.id } } : page
            self.more = page.count == 50
        } catch is CancellationError { } catch {
            if token == generation { records = []; loadedFilter = nil; self.more = false; clearSelection(); self.error = Self.message(error) }
        }
    }
    func selectFromUI(_ id: BugID) {
        let token = beginSelection(id); Task { await loadSelection(id, token: token) }
    }
    func select(_ id: BugID) async { await loadSelection(id, token: beginSelection(id)) }
    private func beginSelection(_ id: BugID) -> Int {
        clearSelection(); selectedID = id; selecting = true; error = nil; return selectionGeneration
    }
    private func loadSelection(_ id: BugID, token: Int) async {
        guard let services else { if token == selectionGeneration { selecting = false }; return }
        defer { if token == selectionGeneration { selecting = false } }
        do {
            let versions = try await services.store.history(id, in: project.scope)
            guard !versions.isEmpty else { throw BugRegistryError.unavailableReference }
            let incoming = try await services.store.list(in: project.scope, statuses: Set(BugStatus.allCases), limit: 50, linkedTo: id)
            try Task.checkCancellation(); guard token == selectionGeneration else { return }
            history = versions; selectedRevision = versions.first?.revision; self.incoming = incoming; moreIncoming = incoming.count == 50
        } catch is CancellationError { } catch { if token == selectionGeneration { self.error = Self.message(error) } }
    }
    func loadMoreIncoming() async {
        guard !selecting, !loadingIncoming, moreIncoming, let id = selectedID, let services else { return }
        let token = selectionGeneration; loadingIncoming = true
        defer { if token == selectionGeneration { loadingIncoming = false } }
        do {
            let page = try await services.store.list(in: project.scope, statuses: Set(BugStatus.allCases),
                after: incoming.last?.id, limit: 50, linkedTo: id)
            try Task.checkCancellation(); guard token == selectionGeneration else { return }
            incoming += page.filter { item in !incoming.contains { $0.id == item.id } }; moreIncoming = page.count == 50
        } catch is CancellationError { } catch { if token == selectionGeneration { self.error = Self.message(error) } }
    }
    func didPublish(_ record: BugRecord) async {
        guard record.scope == project.scope else { return }
        await load(); if records.contains(where: { $0.id == record.id }) { await select(record.id) }
    }
    func cancel() {
        generation += 1; clearSelection(); records = []; services = nil; loadedFilter = nil; loading = false; more = false; error = nil
    }
    private func clearSelection() {
        selectionGeneration += 1; selectedID = nil; selectedRevision = nil; history = []; incoming = []; selecting = false; moreIncoming = false; loadingIncoming = false
    }
    static func message(_ error: any Error) -> String {
        if error as? BugRegistryError == .staleRevision { return "This bug changed. Reopen its latest version before reviewing." }
        return "The registry or linked bug could not be opened in this project. Check filters and local storage, then refresh. Existing records are preserved."
    }
}
#endif
