#if os(macOS)
import AgentDeskCore
import Combine
import Foundation

struct NativeTraceabilityServices {
    let store: ProjectRequirementStore
    let bugs: ProjectBugStore
    let environments: [ProjectEnvironment]
    let environmentIssue: String?
}
struct TraceabilityBrowserFilter: Hashable {
    var query = ""
    var kind: TraceabilitySubject.Kind?
    var environment: EnvironmentID?
    var includeArchived = false
}
struct NativeTraceReference: Identifiable {
    let linked: TracedRequirement
    let recorded: RequirementVersion
    let current: RequirementVersion?
    var id: RequirementID { linked.id }
    var status: RequirementImpact.Status {
        current == nil ? .unavailable : current?.version == linked.version ? .current : .potentiallyStale
    }
}

@MainActor
final class ProjectTraceabilityModel: ObservableObject {
    let project: ProjectRecord
    @Published var filter = TraceabilityBrowserFilter()
    @Published var historical = false
    @Published private(set) var services: NativeTraceabilityServices?
    @Published private(set) var records: [RequirementTraceRecord] = []
    @Published private(set) var selected: RequirementTraceRecord?
    @Published private(set) var references: [NativeTraceReference] = []
    @Published private(set) var selectedSubject: TraceabilitySubject?
    @Published private(set) var impact: RequirementImpactReport?
    @Published private(set) var bugImpact: BugRequirementImpactReport?
    @Published private(set) var loading = false
    @Published private(set) var selecting = false
    @Published private(set) var loadingImpact = false
    @Published private(set) var more = false
    @Published private(set) var error: String?
    @Published private(set) var impactError: String?
    private let open: () async throws -> NativeTraceabilityServices
    private var generation = 0, selectionGeneration = 0, impactGeneration = 0
    private var loadedFilter: TraceabilityBrowserFilter?
    init(project: ProjectRecord, open: @escaping () async throws -> NativeTraceabilityServices) { self.project = project; self.open = open }

    func load(more: Bool = false) async {
        generation += 1; let token = generation, requested = filter
        let append = more && loadedFilter == requested
        loading = true; error = nil; if !append { clearSelection() }
        defer { if token == generation { loading = false } }
        do {
            let service: NativeTraceabilityServices
            if let existing = services { service = existing } else { service = try await open() }
            guard service.store.scope == project.scope, service.bugs.scope == project.scope else { throw RequirementError.scopeMismatch }
            let page = try await service.store.traces(in: project.scope,
                kinds: requested.kind.map { Set([$0]) } ?? Set(TraceabilitySubject.Kind.allCases), environment: requested.environment,
                includeArchived: requested.includeArchived, after: append ? records.last?.subject : nil, limit: 50, query: requested.query)
            try Task.checkCancellation(); guard token == generation, requested == filter else { return }
            services = service; loadedFilter = requested
            records = append ? records + page.filter { value in !records.contains { $0.subject == value.subject } } : page
            self.more = page.count == 50
        } catch is CancellationError { } catch {
            if token == generation { records = []; loadedFilter = nil; self.more = false; clearSelection(); self.error = Self.message(error) }
        }
    }
    func selectFromUI(_ subject: TraceabilitySubject) {
        let token = beginSelection(subject); Task { await loadSelection(subject, token: token) }
    }
    func select(_ subject: TraceabilitySubject) async { await loadSelection(subject, token: beginSelection(subject)) }
    private func beginSelection(_ subject: TraceabilitySubject) -> Int {
        clearSelection(); selectedSubject = subject; selecting = true; error = nil; return selectionGeneration
    }
    private func loadSelection(_ subject: TraceabilitySubject, token: Int) async {
        guard let services else { if token == selectionGeneration { selecting = false }; return }
        defer { if token == selectionGeneration { selecting = false } }
        do {
            guard let record = try await services.store.trace(subject, in: project.scope) else { throw RequirementValidationError.requirementUnavailable }
            var references: [NativeTraceReference] = []
            for linked in record.requirements {
                try Task.checkCancellation()
                guard let recorded = try await services.store.resolve(linked.id, selection: .historical(version: linked.version),
                    in: project.scope, environment: record.environment), try recorded.fingerprint == linked.fingerprint else { throw RequirementError.invalidDocument }
                let current = try await services.store.resolve(linked.id, in: project.scope, environment: record.environment)
                references.append(.init(linked: linked, recorded: recorded, current: current))
            }
            try Task.checkCancellation(); guard token == selectionGeneration else { return }
            selected = record; self.references = references
            if let first = references.first { await loadImpact(first.id) }
        } catch is CancellationError { } catch { if token == selectionGeneration { self.error = Self.message(error) } }
    }
    func loadImpact(_ id: RequirementID) async {
        guard let services else { return }
        impactGeneration += 1; let token = impactGeneration
        loadingImpact = true; impact = nil; bugImpact = nil; impactError = nil
        defer { if token == impactGeneration { loadingImpact = false } }
        do {
            let report = try await services.store.impact(of: id, in: project.scope)
            let bugs = try await services.bugs.requirementImpact(of: id, in: project.scope)
            try Task.checkCancellation(); guard token == impactGeneration else { return }
            impact = report; bugImpact = bugs
        } catch is CancellationError { } catch { if token == impactGeneration { impactError = Self.message(error) } }
    }
    func didPublish(_ record: RequirementTraceRecord) async {
        guard record.scope == project.scope else { return }
        await load(); if records.contains(where: { $0.subject == record.subject }) { await select(record.subject) }
    }
    func cancel() {
        generation += 1; clearSelection(); services = nil; records = []; loadedFilter = nil; loading = false; more = false; error = nil
    }
    private func clearSelection() {
        selectionGeneration += 1; impactGeneration += 1
        selectedSubject = nil; selected = nil; references = []; historical = false; selecting = false
        impact = nil; bugImpact = nil; impactError = nil; loadingImpact = false
    }
    static func message(_ error: any Error) -> String {
        if error as? RequirementError == .staleVersion { return "These links or requirements changed. Reload and review the current versions." }
        return "Traceability could not be resolved for this project. Check the links, filters and local storage, then refresh. Missing data is not treated as verified coverage."
    }
}
#endif
