#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import AgentDeskRuntime
import AgentDeskSecurity
import Combine
import Foundation

/// Incrementally reads authorized, already-redacted evidence. Never consumes raw provider output.
@MainActor
final class NativeLiveOutputModel: ObservableObject {
    struct Entry: Identifiable {
        let record: EvidenceRecord
        let text: String
        var id: UUID { record.id }
    }
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var abbreviated = false
    @Published private(set) var errorMessage: String?
    private(set) var hasMore = false
    private var reader: (any RunEvidenceReading)?
    private var context: RedactionContext?
    private var agentID: AgentID?
    private var cursor: Int64 = 0
    private var generation = 0

    @discardableResult
    func bind(_ reader: any RunEvidenceReading, context: RedactionContext, agentID: AgentID) -> Int {
        clear(); self.reader = reader; self.context = context; self.agentID = agentID
        return generation
    }
    func clear(if token: Int? = nil) {
        guard token == nil || token == generation else { return }
        generation += 1; reader = nil; context = nil; agentID = nil; cursor = 0
        entries = []; abbreviated = false; errorMessage = nil; hasMore = false
    }

    /// One bounded page per refresh; non-output records also advance the sequence cursor.
    func refresh(_ token: Int) async -> Bool {
        guard token == generation, let reader, let context, let agentID else { return false }
        do {
            let records = try await reader.evidenceRecords(for: context.runID, after: cursor, limit: 50)
            guard token == generation else { return false }
            var next = cursor, additions: [Entry] = [], clipped = false
            for record in records {
                try Task.checkCancellation()
                guard token == generation else { return false }
                guard record.context == context, record.agentID == agentID, record.sequence > next else {
                    throw EvidenceStoreError.conflictingRecord
                }
                next = record.sequence
                guard record.source == .providerResponse, record.basis == .interpretation,
                      record.kind == .trace || record.kind == .output else { continue }
                let content: StoredEvidenceContent
                if record.kind == .trace {
                    guard let trace = try await reader.trace(record.id, for: context.runID), trace.record == record else {
                        throw EvidenceStoreError.missingArtifact
                    }
                    content = trace.content
                } else {
                    guard let artifact = try await reader.artifact(record.id, for: context.runID) else {
                        throw EvidenceStoreError.missingArtifact
                    }
                    content = artifact
                }
                guard content.classification != .secret else { throw EvidenceStoreError.invalidInput }
                let text = String(content.text.prefix(16_384))
                clipped = clipped || text != content.text
                additions.append(Entry(record: record, text: text))
            }
            try Task.checkCancellation()
            guard token == generation else { return false }
            entries += additions; cursor = next; abbreviated = abbreviated || clipped; hasMore = records.count == 50
            var bytes = entries.reduce(0) { $0 + $1.text.utf8.count }
            while entries.count > 100 || bytes > 262_144 {
                bytes -= entries.removeFirst().text.utf8.count; abbreviated = true
            }
            errorMessage = nil
            return true
        } catch is CancellationError { return false }
        catch {
            guard token == generation else { return false }
            entries = []; errorMessage = "Live output could not be read. Open saved evidence to retry."
            return false
        }
    }
}
#endif
