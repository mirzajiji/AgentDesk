#if os(macOS)
import AgentDeskCore
import AgentDeskRuntime
import AgentDeskSecurity
import Combine
import Foundation

enum NativeBugDraft {
    case ticket(BugTicketEvidenceDraft)
    case report(PreparedCityPayReport)
    var title: String {
        switch self { case .ticket(let draft): "Evidence for \(draft.ticket.key)"; case .report(let draft): draft.title }
    }
    var text: String {
        switch self { case .ticket(let draft): draft.content.text; case .report(let draft): draft.content.text }
    }
}

/// Holds a service-bound, sanitized review; never collects raw registry data itself.
@MainActor
final class NativeBugReviewModel: ObservableObject {
    let scope: ProjectScope
    let incomingID: BugID
    let environment: EnvironmentID
    @Published private(set) var review: PreparedBugReview?
    @Published private(set) var decision: PreparedBugDecision? { didSet { pendingDecision = decision } }
    @Published private(set) var draft: NativeBugDraft?
    private var pendingDecision: PreparedBugDecision?
    @Published private(set) var busy = false
    @Published private(set) var error: String?
    private let service: NativeRunService
    private let loadReview: () async throws -> PreparedBugReview
    private let validateReview: (PreparedBugReview) async throws -> Void
    private let prepareDecision: (PreparedBugReview, BugID, BugReviewDecision.Resolution, String) async throws -> PreparedBugDecision
    private let publishDecision: (PreparedBugDecision) async throws -> BugRecord
    private let cancelDecision: (PreparedBugDecision) async -> Void
    private var generation = 0

    init(service: NativeRunService, catalog: WorkspaceCatalog, incomingID: BugID,
         validateContext: @escaping () async throws -> Void = {}) {
        self.service = service
        prepareDecision = { review, existing, resolution, reason in
            try await validateContext()
            return try await service.prepareBugDecision(review, existingID: existing, resolution: resolution, reason: reason)
        }
        publishDecision = { decision in
            try await validateContext()
            return try await service.publishBugDecision(decision)
        }
        cancelDecision = { await service.cancelBugDecision($0) }
        scope = service.scope; environment = service.environmentID; self.incomingID = incomingID
        loadReview = {
            try await validateContext()
            return try await service.prepareBugReview(catalog: catalog, incomingID: incomingID)
        }
        validateReview = {
            try await validateContext()
            try await service.validateBugReview($0)
            try await validateContext()
        }
    }

    func load() async {
        generation += 1; let token = generation
        await discardDecision()
        guard token == generation else { return }
        busy = true; review = nil; draft = nil; error = nil
        defer { if token == generation { busy = false } }
        do {
            let value = try await loadReview()
            guard value.scope == scope, value.environment == environment, value.incomingID == incomingID else {
                throw BugRegistryError.scopeMismatch
            }
            try await validateReview(value)
            try Task.checkCancellation(); guard token == generation else { return }
            review = value
        } catch is CancellationError { } catch {
            if token == generation { self.error = "The current evidence and requirements could not be verified. Refresh after checking the project context and permissions." }
        }
    }

    func currentReview() async throws -> PreparedBugReview {
        guard !busy, let review else { throw BugRegistryError.invalidReview }
        let token = generation
        do {
            try await validateReview(review)
            try Task.checkCancellation(); guard token == generation else { throw BugRegistryError.invalidReview }
            return review
        } catch {
            if token == generation {
                self.review = nil
                self.error = "This review changed, expired or lost authorization. Refresh before deciding or preparing a report."
            }
            throw error
        }
    }

    func prepareResolution(existingID: BugID, resolution: BugReviewDecision.Resolution, reason: String) async {
        guard !busy, decision == nil, let review else { return }
        busy = true; draft = nil; error = nil; let token = generation
        defer { if token == generation { busy = false } }
        do {
            try await validateReview(review)
            let value = try await prepareDecision(review, existingID, resolution, reason)
            guard token == generation, !Task.isCancelled else { await cancelDecision(value); return }
            decision = value
        } catch {
            if token == generation {
                self.error = error as? CatalogError == .busy
                    ? "Project storage is busy. Try preparing the decision again shortly."
                    : "The decision could not be prepared. Check the reason and refresh the current evidence."
            }
        }
    }
    func publishResolution() async {
        guard !busy, let decision else { return }
        busy = true; draft = nil; error = nil; let token = generation
        do {
            _ = try await publishDecision(decision)
            guard token == generation else { return }
            self.decision = nil; busy = false
            await load()
        } catch {
            await cancelDecision(decision)
            if token == generation {
                self.decision = nil; busy = false; review = nil
                self.error = error as? CatalogError == .busy
                    ? "Project storage is busy. The decision was not saved; refresh and review it again."
                    : "The decision was not saved. Refresh and review the current registry before trying again."
            }
        }
    }
    func prepareTicketAddition(existingID: BugID) async {
        await prepareDraft { [service] review in
            .ticket(try await service.prepareBugTicketEvidence(review, existingID: existingID))
        }
    }
    func prepareReport(context: CityPayReportContext, groupedIDs: [BugID], problem: String?) async {
        await prepareDraft { [service] review in
            .report(try await service.prepareCityPayReport(review, context: context, groupedIDs: groupedIDs, problem: problem))
        }
    }
    private func prepareDraft(_ operation: (PreparedBugReview) async throws -> NativeBugDraft) async {
        guard !busy, decision == nil, let review else { return }
        busy = true; draft = nil; error = nil; let token = generation
        defer { if token == generation { busy = false } }
        do {
            try await validateReview(review)
            let value = try await operation(review)
            try await validateReview(review)
            try Task.checkCancellation(); guard token == generation else { return }
            draft = value
        } catch {
            if token == generation {
                let reason: String
                switch error {
                case CatalogError.busy: reason = "Project storage is busy. Try again shortly."
                case BugRegistryError.staleRevision: reason = "The registry changed."
                case BugRegistryError.invalidReview: reason = "The comparison or ticket is not eligible for this draft."
                case BugRegistryError.unavailableReference: reason = "Required evidence is unavailable."
                case BugRegistryError.scopeMismatch: reason = "The evidence belongs to another context."
                case BugRegistryError.limitExceeded: reason = "The draft exceeds the supported size."
                case is RedactionError: reason = "The content could not be safely redacted."
                default: reason = "The current context or source data could not be verified."
                }
                self.error = "A draft could not be prepared. \(reason) Refresh and review the current evidence."
            }
        }
    }
    func validatedDraftText() async throws -> String {
        guard !busy, let draft, let review else { throw BugRegistryError.invalidReview }
        let token = generation
        do {
            try await validateReview(review)
            switch draft {
            case .ticket(let value): try await service.validateBugTicketEvidence(value)
            case .report(let value): try await service.validateCityPayReport(value)
            }
            try Task.checkCancellation(); guard token == generation else { throw BugRegistryError.invalidReview }
            return draft.text
        } catch {
            if token == generation { self.draft = nil; self.error = "This draft is no longer current. Refresh and prepare it again before copying." }
            throw error
        }
    }

    func discardDecision() async {
        let previous = decision; decision = nil
        if let previous { await cancelDecision(previous) }
    }
    func cancel() {
        generation += 1; review = nil; draft = nil; busy = false; error = nil
        let previous = decision, cancel = cancelDecision; decision = nil
        if let previous { Task { await cancel(previous) } }
    }
    deinit {
        let previous = pendingDecision, service = service
        if let previous { Task { await service.cancelBugDecision(previous) } }
    }
}
#endif
