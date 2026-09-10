import AgentDeskCore
import AgentDeskPersistence
import Foundation

/// Read-only local evidence boundary shared by an active session and an archive browser.
public protocol RunEvidenceReading: AnyObject, Sendable {
    func runs(before: RunID?, limit: Int) async throws -> [StoredRun]
    func evidenceRecords(for: RunID, after: Int64, limit: Int) async throws -> [EvidenceRecord]
    func artifact(_ id: UUID, for run: RunID) async throws -> StoredEvidenceContent?
    func trace(_ id: UUID, for run: RunID) async throws -> StoredTrace?
}
