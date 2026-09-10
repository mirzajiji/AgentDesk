#if os(macOS)
import AgentDeskCore
import AgentDeskSecurity
import Combine
import Foundation

@MainActor
final class BugEditorModel: ObservableObject {
    let store: ProjectBugStore
    let existing: BugRecord?
    @Published var draft: BugDraft
    @Published var editRequirementLinks = false
    @Published var requirementLinks: [NativeRequirementLink] = []
    @Published private(set) var proposal: BugProposal? { didSet { pending = proposal } }
    @Published private(set) var fields: [BugReviewField] = []
    @Published private(set) var busy = false
    @Published private(set) var redacted = false
    @Published private(set) var error: String?
    private var pending: BugProposal?
    private var generation = 0, unavailable = false

    init(store: ProjectBugStore, existing: BugRecord?) {
        self.store = store; self.existing = existing?.scope == store.scope ? existing : nil
        requirementLinks = self.existing?.requirements.map {
            .init(requirement: $0.requirement.id.rawValue, historical: $0.requirement.historical,
                  version: String($0.requirement.version), role: $0.role)
        } ?? []
        draft = .init(title: "", sources: [.init(scope: store.scope, origin: .humanStatement, label: "Local user report", capturedAt: Date())], changeReason: "")
        do {
            if let existing {
                guard existing.scope == store.scope else { throw BugRegistryError.scopeMismatch }
                let safe = try BugPresentation.sanitized(existing.content, scope: store.scope)
                draft = safe.draft; draft.changeReason = ""; redacted = safe.changed
            }
        } catch { unavailable = true; self.error = Self.message(error) }
    }
    deinit { let store = store, proposal = pending; if let proposal { Task { await store.cancel(proposal) } } }

    func prepare() async {
        guard !busy, proposal == nil, !unavailable else { return }
        busy = true; error = nil; let token = generation
        defer { if token == generation { busy = false } }
        do {
            let safe = try BugPresentation.sanitized(draft, scope: store.scope)
            try safe.draft.validate(in: store.scope, id: existing?.id)
            let old = try existing.map { try BugPresentation.sanitized($0.content, scope: store.scope).draft }
            var fields = try BugPresentation.fields(before: old, after: safe.draft)
            let requests: [BugRequirementRequest]? = editRequirementLinks ? try requirementLinks.map { link in
                let request = try link.request()
                guard try TraceabilityEditorModel.safeText(request.id.rawValue, scope: store.scope,
                    environment: safe.draft.environment ?? EnvironmentID()).redactionCount == 0 else { throw BugRegistryError.invalidDocument }
                return .init(role: link.role, requirement: request)
            } : nil
            // Nil requirement requests preserve exact creation references on an ordinary edit.
            let proposal = try await store.prepare(safe.draft, requirements: requests, id: existing?.id, expectedRevision: existing?.revision, in: store.scope)
            guard token == generation, !Task.isCancelled else { await store.cancel(proposal); return }
            if proposal.candidate.requirements != (existing?.requirements ?? []) {
                fields.append(.init(id: "requirementLinks", title: "Requirement associations", before: existing.map { Self.describe($0.requirements) },
                    after: Self.describe(proposal.candidate.requirements)))
            }
            draft = safe.draft; redacted = redacted || safe.changed; self.fields = fields; self.proposal = proposal
        } catch is CancellationError { } catch { if token == generation { self.error = Self.message(error) } }
    }
    func publish() async -> BugRecord? {
        guard !busy, let proposal else { return nil }
        busy = true; error = nil; let token = generation
        defer { if token == generation { busy = false } }
        do {
            let result = try await store.publishReviewed(proposal, in: store.scope)
            guard token == generation else { return nil }
            self.proposal = nil; fields = []; return result
        } catch {
            await store.cancel(proposal)
            if token == generation { self.proposal = nil; fields = []; self.error = Self.message(error) }
            return nil
        }
    }
    func cancelReview() async {
        generation += 1; let proposal = proposal
        self.proposal = nil; fields = []; busy = false
        if let proposal { await store.cancel(proposal) }
    }
    func json() throws -> String { try BugPresentation.json(draft) }
    func applyJSON(_ text: String) throws {
        guard !busy, proposal == nil, !unavailable else { throw BugRegistryError.invalidReview }
        let value = try ConfigurationJSON.decode(BugDraft.self, from: Data(text.utf8))
        try value.validate(in: store.scope, id: existing?.id)
        guard value.comparisonReview == existing?.content.comparisonReview else { throw BugRegistryError.invalidReview }
        let safe = try BugPresentation.sanitized(value, scope: store.scope)
        try safe.draft.validate(in: store.scope, id: existing?.id)
        draft = safe.draft; redacted = redacted || safe.changed
    }
    static func message(_ error: any Error) -> String {
        switch error {
        case BugRegistryError.staleRevision: "This bug changed. Close the editor and reopen its latest version."
        case BugRegistryError.scopeMismatch, RequirementError.scopeMismatch: "A source or reference belongs to another project or environment."
        case BugRegistryError.invalidReview: "This review expired or changes protected comparison metadata. Prepare a fresh review from the latest bug."
        case BugRegistryError.unavailableReference: "A linked bug or requirement is unavailable or changed. Check the references and prepare a fresh review."
        default: "Check the title, reason, ticket and references. Observed findings need observed provenance and root/expected/actual behavior. Blocked findings need a valid blocked-by link."
        }
    }
    private static func describe(_ links: [BugRequirementReference]) -> String {
        links.isEmpty ? "None" : links.map {
            "\($0.role.rawValue): \($0.requirement.id) · v\($0.requirement.version) · \($0.requirement.historical ? "explicitly historical" : "active at review")"
        }.joined(separator: "\n")
    }
}
#endif
