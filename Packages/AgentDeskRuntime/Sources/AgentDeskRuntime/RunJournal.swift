import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation

/// Serializes authoritative progress and redacted evidence for one run.
actor RunJournal {
    private let prepared: PreparedRunData
    private let lifecycle: RunLifecycleService
    private var sequence: Int64 = 0
    private var lastDate = Date(timeIntervalSince1970: 0)
    init(prepared: PreparedRunData, lifecycle: RunLifecycleService) { self.prepared = prepared; self.lifecycle = lifecycle }
    private var id: RunID { prepared.preview.runID }
    private var scope: ProjectScope { prepared.context.scope }
    private func date() throws -> Date {
        let now = Date()
        guard now >= lastDate else { throw RunCoordinatorError.persistenceUnavailable }
        lastDate = now; return now
    }
    private func change(_ change: WorkPlanChange) async throws {
        sequence = try await lifecycle.changeProgress(change, for: id, in: scope, expectedSequence: sequence, at: date()).sequence
    }
    func perform(provider: any ExecutionProvider, beforeDispatch: @Sendable () async throws -> Void) async throws -> UUID {
        guard let run = try await lifecycle.run(id, in: scope) else { throw RunCoordinatorError.persistenceUnavailable }
        sequence = run.sequence
        sequence = try await lifecycle.transition(id, in: scope, to: .running, expectedSequence: sequence, at: date()).sequence
        try await change(.transition(prepared.stages[0].id, to: .running))
        if let repository = prepared.repository {
            do { try await save(try await repository.captureBaseline()) }
            catch is CancellationError { throw CancellationError() }
            catch { throw RunCoordinatorError.repositoryFailed }
        }
        try await change(.transition(prepared.stages[0].id, to: .completed))
        try await change(.transition(prepared.stages[1].id, to: .running))
        try Task.checkCancellation()
        do { try await prepared.knowledge?.validate() }
        catch is CancellationError { throw CancellationError() }
        catch { throw RunCoordinatorError.invalidPreparation }
        try await beforeDispatch()
        let execution = try await provider.start(prepared.request)
        defer { execution.cancel() }
        var validator = RunEventValidator(request: prepared.request)
        for try await event in execution.events {
            try Task.checkCancellation()
            switch try validator.accept(event) {
            case .started: try await trace("Provider started.", source: .runtime, basis: .observed)
            case .activity(let item, let title, let completed):
                if !completed {
                    try await change(.add(WorkItemDefinition(id: item, kind: .step, parentStageID: prepared.stages[1].id, title: title)))
                    try await change(.transition(item, to: .running))
                } else { try await change(.transition(item, to: .completed)) }
            case .message(let text): try await trace(text, source: .providerResponse, basis: .interpretation)
            case .completed: break
            }
        }
        try Task.checkCancellation()
        let final = try validator.finish()
        try await change(.transition(prepared.stages[1].id, to: .completed))
        try await change(.transition(prepared.stages[2].id, to: .running))
        if let repository = prepared.repository {
            do { try await save(try await repository.captureChanges()) }
            catch is CancellationError { throw CancellationError() }
            catch { throw RunCoordinatorError.repositoryFailed }
        }
        // The final output is the last output artifact on a successfully completed run.
        let safe = try prepared.request.outputSchema == nil
            ? prepared.redactor.redactText(final, in: prepared.context)
            : prepared.redactor.redactJSON(final, in: prepared.context)
        let record = try await prepared.evidence.publishArtifact(safe, kind: .output, source: .providerResponse,
            basis: .interpretation, format: prepared.request.outputSchema == nil ? .text : .json, at: date())
        try await change(.transition(prepared.stages[2].id, to: .completed))
        return record.id
    }
    private func save(_ result: RepositoryEvidence) async throws {
        _ = try await prepared.evidence.publishArtifact(result.snapshot, kind: .repositorySnapshot, source: .repository,
            basis: .observed, format: .json, at: date())
        _ = try await prepared.evidence.publishArtifact(result.diff, kind: .diff, source: .repository,
            basis: .observed, format: .diff, at: date())
    }
    private func trace(_ text: String, source: EvidenceSource, basis: EvidenceBasis) async throws {
        let safe = try prepared.redactor.redactText(text, in: prepared.context)
        if safe.text.utf8.count <= 65_536 {
            _ = try await prepared.evidence.appendTrace(safe, source: source, basis: basis, at: date())
        } else {
            _ = try await prepared.evidence.publishArtifact(safe, kind: .output, source: source, basis: basis, at: date())
        }
    }
    func complete() async throws {
        try Task.checkCancellation()
        sequence = try await lifecycle.transition(id, in: scope, to: .completed, expectedSequence: sequence, at: date()).sequence
    }

    /// Cancellation must not cancel the terminal database write. The detached cleanup is awaited.
    /// A regressed wall clock reuses the last recorded instant, never an invented later timestamp.
    static func terminate(_ id: RunID, scope: ProjectScope, lifecycle: RunLifecycleService, evidence: EvidenceStore?,
                          failure: RunCoordinatorError, state: RunState) async -> RunOutcome {
        await Task.detached {
            do {
                guard let run = try await lifecycle.run(id, in: scope), !run.state.isTerminal,
                      let last = try await lifecycle.history(for: id, in: scope, after: run.sequence - 1, limit: 1).last else {
                    return RunOutcome(runID: id, state: nil, failure: .persistenceUnavailable, finalArtifactID: nil)
                }
                let now = Date(), date = now.timeIntervalSince1970.isFinite ? max(now, last.recordedAt) : last.recordedAt
                // A missing/corrupt evidence binding must not leave an interrupted run appearing active.
                if let evidence, let redactor = try? ContentRedactor(context: evidence.context),
                   let text = try? redactor.redactText("Run stopped: \(failure.rawValue). Completion is not verified.", in: evidence.context) {
                    _ = try? await evidence.appendTrace(text, source: .runtime, basis: .observed, at: date)
                }
                _ = try await lifecycle.transition(id, in: scope, to: state, expectedSequence: run.sequence, at: date)
                return RunOutcome(runID: id, state: state, failure: failure, finalArtifactID: nil)
            } catch {
                return RunOutcome(runID: id, state: nil, failure: .persistenceUnavailable, finalArtifactID: nil)
            }
        }.value
    }
}
