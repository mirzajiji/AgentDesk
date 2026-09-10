#if os(macOS)
import AgentDeskCore
import AgentDeskSecurity
import Combine
import Foundation

struct NativeRequirementLink: Identifiable, Equatable {
    let id = UUID()
    var requirement = ""
    var historical = false
    var version = ""
    var role: BugRequirementRequest.Role = .affects
    func request() throws -> RequirementLinkRequest {
        guard let id = RequirementID(rawValue: requirement.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RequirementError.invalidDocument }
        if historical {
            guard let number = Int(version), (1...1_000_000).contains(number) else { throw RequirementError.invalidDocument }
            return .init(id: id, historicalVersion: number)
        }
        return .init(id: id)
    }
}

@MainActor
final class TraceabilityEditorModel: ObservableObject {
    let services: NativeTraceabilityServices
    let existing: RequirementTraceRecord?
    @Published var kind: TraceabilitySubject.Kind
    @Published var identifier: String
    @Published var title: String
    @Published var environment: EnvironmentID?
    @Published var links: [NativeRequirementLink]
    @Published var archived: Bool
    @Published var reason = ""
    @Published private(set) var proposal: TraceabilityProposal? { didSet { pending = proposal } }
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var redacted = false
    private var pending: TraceabilityProposal?
    private var generation = 0
    private let unavailable: Bool

    init(services: NativeTraceabilityServices, existing: RequirementTraceRecord? = nil) {
        self.services = services
        unavailable = services.bugs.scope != services.store.scope || (existing != nil && existing?.scope != services.store.scope)
        let record = unavailable ? nil : existing
        self.existing = record
        kind = record?.subject.kind ?? .automatedTest; identifier = record?.subject.id.rawValue ?? ""
        title = record?.title ?? ""; environment = record?.environment ?? services.environments.first?.id
        archived = record?.archived ?? false
        links = record?.requirements.map { .init(requirement: $0.id.rawValue, historical: $0.historical, version: String($0.version)) } ?? [.init()]
        if unavailable { error = "These links or services belong to another project." }
        if let existing = record {
            do { let safe = try Self.safeText(existing.title, scope: services.store.scope, environment: existing.environment); title = safe.text; redacted = safe.redactionCount > 0 }
            catch { title = ""; self.error = Self.message(error) }
        }
    }
    deinit { let store = services.store, proposal = pending; if let proposal { Task { await store.cancelTrace(proposal) } } }

    func prepare() async {
        guard !busy, proposal == nil, !unavailable else { return }
        busy = true; error = nil; let token = generation
        defer { if generation == token { busy = false } }
        do {
            let scope = services.store.scope
            guard services.bugs.scope == scope, existing == nil || existing?.scope == scope, let environment,
                  let id = RequirementID(rawValue: identifier.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw RequirementError.scopeMismatch }
            let subject = TraceabilitySubject(kind: kind, id: id)
            guard existing == nil || existing?.subject == subject else { throw RequirementError.invalidDocument }
            let requests = try links.map { try $0.request() }
            for text in [id.rawValue] + requests.map({ $0.id.rawValue }) {
                guard try Self.safeText(text, scope: scope, environment: environment).redactionCount == 0 else { throw RequirementError.invalidDocument }
            }
            if kind == .bug {
                guard let bugID = BugID(rawValue: id.rawValue), try await services.bugs.record(bugID, in: scope) != nil else { throw BugRegistryError.unavailableReference }
            }
            let safeTitle = try Self.safeText(title, scope: scope, environment: environment)
            let safeReason = try Self.safeText(reason, scope: scope, environment: environment)
            let proposal = try await services.store.prepareTrace(subject: subject, title: safeTitle.text, environment: environment,
                requirements: requests, changeReason: safeReason.text, archived: archived, expectedRevision: existing?.revision, in: scope)
            guard generation == token, !Task.isCancelled else { await services.store.cancelTrace(proposal); return }
            title = safeTitle.text; reason = safeReason.text
            redacted = redacted || safeTitle.redactionCount > 0 || safeReason.redactionCount > 0
            self.proposal = proposal
        } catch is CancellationError { } catch { if token == generation { self.error = Self.message(error) } }
    }
    func publish() async -> RequirementTraceRecord? {
        guard !busy, let proposal else { return nil }
        busy = true; error = nil; let token = generation
        defer { if token == generation { busy = false } }
        do {
            let result = try await services.store.publishReviewedTrace(proposal, in: services.store.scope)
            guard token == generation else { return nil }
            self.proposal = nil; return result
        } catch {
            await services.store.cancelTrace(proposal)
            if token == generation { self.proposal = nil; self.error = Self.message(error) }
            return nil
        }
    }
    func cancelReview() async {
        generation += 1; let proposal = proposal; self.proposal = nil; busy = false
        if let proposal { await services.store.cancelTrace(proposal) }
    }
    static func safeText(_ text: String, scope: ProjectScope, environment: EnvironmentID) throws -> RedactedText {
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        return try ContentRedactor(context: context).redactText(text, in: context)
    }
    static func message(_ error: any Error) -> String {
        switch error {
        case RequirementError.staleVersion: "The links or current requirements changed. Reload and review again."
        case RequirementValidationError.requirementUnavailable: "A requirement version is unavailable in this environment. Choose current active behavior or an explicit available historical version."
        case BugRegistryError.unavailableReference: "A bug subject must identify an existing bug in this project."
        default: "Check the subject identifier, environment, title, reason and requirement links. Historical selection requires a valid version; duplicate links are not allowed."
        }
    }
}
#endif
