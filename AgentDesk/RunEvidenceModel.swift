#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskRuntime
import AgentDeskSecurity
import Combine
import Foundation

@MainActor
final class RunEvidenceModel: ObservableObject {
    @Published private(set) var runs: [StoredRun] = []
    @Published private(set) var records: [EvidenceRecord] = []
    @Published private(set) var selectedRun: RunID?
    @Published private(set) var selectedRecord: EvidenceRecord?
    @Published private(set) var content: StoredEvidenceContent?
    @Published private(set) var errorMessage: String?
    @Published private(set) var moreRuns = false
    @Published private(set) var moreRecords = false
    private var generation = 0
    private var selection = 0
    private var service: (any RunEvidenceReading)?
    var isOpen: Bool { service != nil }

    /// Select the confirmed run and its final artifact using persisted provenance, including later pages.
    func showResult(_ outcome: RunOutcome, using reader: any RunEvidenceReading) async {
        let expectedLoad = generation + (service === reader ? 1 : 2)
        await load(reader)
        guard generation == expectedLoad, service === reader, errorMessage == nil, !Task.isCancelled else { return }
        let loadToken = generation
        let expectedSelection = selection + 1
        await select(outcome.runID)
        guard generation == loadToken, selection == expectedSelection, selectedRun == outcome.runID, errorMessage == nil else { return }
        guard let artifactID = outcome.finalArtifactID else { return }
        while !Task.isCancelled {
            if let record = records.first(where: { $0.id == artifactID }) { await inspect(record); return }
            guard moreRecords else {
                errorMessage = "The final result is unavailable in the saved evidence. Refresh to retry."
                return
            }
            let last = records.last?.sequence
            let expectedSelection = selection + 1
            await select(outcome.runID, more: true)
            guard generation == loadToken, selection == expectedSelection, selectedRun == outcome.runID, errorMessage == nil,
                  records.last?.sequence != last else { return }
        }
    }

    func refresh(older: Bool = false) async {
        guard let service else { return }
        await load(service, older: older)
    }

    func clear() {
        generation += 1; selection += 1; service = nil
        runs = []; records = []; selectedRun = nil; selectedRecord = nil; content = nil
        errorMessage = nil; moreRuns = false; moreRecords = false
    }
    func load(_ service: any RunEvidenceReading, older: Bool = false) async {
        if self.service !== service { clear(); self.service = service }
        generation += 1; let token = generation
        do {
            let page = try await service.runs(before: older ? runs.last?.id : nil, limit: 25)
            try Task.checkCancellation()
            guard generation == token else { return }
            runs = older ? runs + page.filter { item in !runs.contains(where: { $0.id == item.id }) } : page
            moreRuns = page.count == 25; errorMessage = nil
        } catch {
            if generation == token {
                selection += 1; runs = []; records = []; selectedRun = nil; selectedRecord = nil; content = nil
                moreRuns = false; moreRecords = false; errorMessage = NativeRunSession.message(error)
            }
        }
    }
    func select(_ id: RunID, more: Bool = false) async {
        guard let service else { return }
        selection += 1; let token = selection
        if !more || selectedRun != id { records = []; selectedRecord = nil; content = nil }
        selectedRun = id; errorMessage = nil
        do {
            let page = try await service.evidenceRecords(for: id, after: more ? records.last?.sequence ?? 0 : 0, limit: 50)
            try Task.checkCancellation()
            guard selection == token else { return }
            records += page.filter { item in !records.contains(where: { $0.id == item.id }) }
            moreRecords = page.count == 50
        } catch { if selection == token { errorMessage = NativeRunSession.message(error); moreRecords = false } }
    }
    func inspect(_ record: EvidenceRecord) async {
        guard let service, record.context.runID == selectedRun, records.contains(record) else { return }
        selection += 1; let token = selection
        selectedRecord = record; content = nil; errorMessage = nil
        do {
            let value: StoredEvidenceContent?
            if record.kind == .trace { value = try await service.trace(record.id, for: record.context.runID)?.content }
            else { value = try await service.artifact(record.id, for: record.context.runID) }
            try Task.checkCancellation()
            guard selection == token else { return }
            guard let value else { throw EvidenceStoreError.missingArtifact }
            content = value
        } catch { if selection == token { errorMessage = NativeRunSession.message(error) } }
    }
}
#endif
