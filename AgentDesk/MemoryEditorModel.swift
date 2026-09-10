#if os(macOS)
import AgentDeskCore
import Combine
import Foundation

@MainActor
final class MemoryEditorModel: ObservableObject {
    let store: ProjectMemoryStore
    private let existing: MemoryRecord?
    @Published var draft: MemoryDraft
    @Published private(set) var proposal: MemoryProposal? { didSet { pending = proposal } }
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    @Published private(set) var redacted = false
    @Published private(set) var before: String?
    @Published private(set) var after: String?
    @Published private(set) var changes: [MemoryReviewChange] = []
    private var pending: MemoryProposal?
    private var generation = 0
    private var unavailable = false
    var isNew: Bool { existing == nil }

    init(store: ProjectMemoryStore, existing: MemoryRecord?, kind: MemoryKind = .note) {
        self.store = store; self.existing = existing
        draft = MemoryDraft(kind: kind, title: "", body: "", sources: [
            .init(scope: store.scope, origin: .humanStatement, label: "Local user statement", capturedAt: Date())
        ], changeReason: "")
        do {
            if let existing {
                guard existing.scope == store.scope else { throw RequirementError.scopeMismatch }
                let safe = try MemoryPresentation.sanitized(existing.content, scope: store.scope)
                draft = safe.draft; draft.changeReason = ""; redacted = safe.changed
            }
        } catch { unavailable = true; self.error = Self.message(error) }
    }
    deinit {
        let store = store, proposal = pending
        if let proposal { Task { await store.cancel(proposal) } }
    }
    func prepare() async {
        guard !busy, proposal == nil, !unavailable else { return }
        busy = true; error = nil; let token = generation
        defer { if generation == token { busy = false } }
        do {
            let safe = try MemoryPresentation.sanitized(draft, scope: store.scope)
            try safe.draft.validate(in: store.scope)
            let old = try existing.map { try MemoryPresentation.sanitized($0.content, scope: store.scope).draft }
            let before = try old.map { try MemoryPresentation.json($0) }, after = try MemoryPresentation.json(safe.draft)
            let changes = try MemoryPresentation.changes(before: old, after: safe.draft)
            let proposal = try await store.prepare(safe.draft, id: existing?.id, expectedRevision: existing?.revision, in: store.scope)
            guard token == generation, !Task.isCancelled else { await store.cancel(proposal); return }
            draft = safe.draft; redacted = redacted || safe.changed
            self.before = before; self.after = after; self.changes = changes; self.proposal = proposal
        } catch is CancellationError {} catch { if token == generation { self.error = Self.message(error) } }
    }
    func publish() async -> MemoryRecord? {
        guard !busy, let proposal else { return nil }
        busy = true; error = nil; let token = generation
        defer { if token == generation { busy = false } }
        do {
            let value = try await store.publishReviewed(proposal, in: store.scope)
            guard token == generation else { return nil }
            self.proposal = nil; before = nil; after = nil; changes = []
            return value
        } catch {
            await store.cancel(proposal)
            if token == generation { self.proposal = nil; before = nil; after = nil; changes = []; self.error = Self.message(error) }
            return nil
        }
    }
    func cancelReview() async {
        generation += 1; let proposal = proposal
        self.proposal = nil; before = nil; after = nil; changes = []; busy = false
        if let proposal { await store.cancel(proposal) }
    }
    func json() throws -> String { try MemoryPresentation.json(draft) }
    func applyJSON(_ text: String) throws {
        guard !busy, proposal == nil, !unavailable else { throw RequirementError.invalidReview }
        let value = try ConfigurationJSON.decode(MemoryDraft.self, from: Data(text.utf8))
        try value.validate(in: store.scope)
        let safe = try MemoryPresentation.sanitized(value, scope: store.scope)
        try safe.draft.validate(in: store.scope)
        draft = safe.draft; redacted = redacted || safe.changed
    }
    static func message(_ error: any Error) -> String {
        switch error {
        case RequirementError.staleVersion: "This memory changed. Close the editor and reopen its latest version."
        case RequirementError.invalidReview: "This review expired or is no longer valid. Review the changes again."
        case RequirementError.scopeMismatch: "This memory belongs to another project."
        default: "Check the title, content, reason, sources and classification. Confirmed knowledge needs a topic; only inbox entries can be ignored."
        }
    }
}
#endif
