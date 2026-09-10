#if os(macOS)
import AgentDeskCore
import Combine
import Foundation

@MainActor
final class RequirementEditorModel: ObservableObject {
    let existing: RequirementVersion?
    let store: ProjectRequirementStore
    @Published var idText: String
    @Published var draft: RequirementDraft
    @Published private(set) var proposal: RequirementProposal? { didSet { pendingReview = proposal } }
    @Published private(set) var changes: [RequirementChange] = []
    @Published private(set) var isBusy = false
    @Published private(set) var errorMessage: String?
    private var generation = 0
    private var pendingReview: RequirementProposal?

    init(store: ProjectRequirementStore, existing: RequirementVersion?) {
        self.store = store; self.existing = existing
        idText = existing?.id.rawValue ?? ""
        draft = existing?.content ?? RequirementDraft(description: "", changeReason: "")
        if existing != nil { draft.changeReason = "" }
    }
    deinit {
        let store = store, proposal = pendingReview
        if let proposal { Task { await store.cancel(proposal) } }
    }
    func prepare() async {
        guard !isBusy, proposal == nil else { return }
        isBusy = true; errorMessage = nil; let token = generation
        defer { if generation == token { isBusy = false } }
        do {
            guard let id = RequirementID(rawValue: idText), existing == nil || existing?.id == id,
                  existing == nil || existing?.scope == store.scope else { throw RequirementError.invalidDocument }
            let changes = try draft.changes(from: existing?.content)
            let pending = try await store.prepare(draft, id: id, expectedVersion: existing?.version, in: store.scope)
            guard generation == token, !Task.isCancelled else { await store.cancel(pending); return }
            self.changes = changes; proposal = pending
        } catch is CancellationError {} catch { if generation == token { errorMessage = Self.message(error) } }
    }
    func publish() async -> RequirementVersion? {
        guard !isBusy, let proposal else { return nil }
        isBusy = true; errorMessage = nil; let token = generation
        defer { if generation == token { isBusy = false } }
        do {
            // Only the already reviewed candidate reaches the store, even if a binding changes elsewhere.
            let result = try await store.publishReviewed(proposal, in: store.scope)
            guard generation == token else { return nil }
            self.proposal = nil; changes = []
            return result
        } catch {
            await store.cancel(proposal)
            if generation == token { self.proposal = nil; changes = []; errorMessage = Self.message(error) }
            return nil
        }
    }
    func cancelReview() async {
        generation += 1; let pending = proposal
        proposal = nil; changes = []; isBusy = false
        if let pending { await store.cancel(pending) }
    }
    func json() throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(draft), as: UTF8.self)
    }
    func applyJSON(_ text: String) throws {
        guard !isBusy, proposal == nil else { throw RequirementError.invalidReview }
        let value = try ConfigurationJSON.decode(RequirementDraft.self, from: Data(text.utf8))
        try value.validate(); draft = value
    }
    static func message(_ error: any Error) -> String {
        switch error {
        case RequirementError.staleVersion: "This requirement changed. Close the editor and reopen the latest version before reviewing again."
        case RequirementError.invalidReview: "This review expired or is no longer valid. Review the changes again."
        case RequirementError.scopeMismatch: "This requirement is not available in the selected project."
        case RequirementError.limitExceeded: "This requirement or its history exceeds the supported size limit."
        case CatalogError.busy: "Project files are busy. Try again when the other operation finishes."
        default: "Check the requirement ID, description, change reason and structured fields. Existing versions have been preserved."
        }
    }
}
#endif
