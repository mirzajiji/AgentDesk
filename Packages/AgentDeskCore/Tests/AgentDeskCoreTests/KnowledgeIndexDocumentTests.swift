import Foundation
import XCTest
@testable import AgentDeskCore

final class KnowledgeIndexDocumentTests: XCTestCase {
    func testLogicalPathsAndSubtreeFiltersUseSegmentBoundaries() throws {
        let filter = try KnowledgePathFilter(include: ["api/paynet/**"], exclude: ["api/paynet/finance/**"])
        for path in ["api/paynet", "api/paynet/response"] { XCTAssertTrue(filter.permits(try XCTUnwrap(KnowledgePath(rawValue: path)))) }
        for path in ["api/paynet-private/response", "api/paynet/finance/response", "API/paynet/response"] {
            XCTAssertFalse(filter.permits(try XCTUnwrap(KnowledgePath(rawValue: path))))
        }
        for path in ["", "/api", "api/../private", "api//x", "file://x", "api\\private", "api/*"] { XCTAssertNil(KnowledgePath(rawValue: path)) }
    }

    func testIndexSnapshotKeepsSourceIdentityAndOptionalPathPreservesLegacyEncoding() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let source = MemorySource(scope: scope, origin: .interpretation, label: "Synthetic", capturedAt: Date(timeIntervalSinceReferenceDate: 1000))
        var draft = MemoryDraft(kind: .note, topic: .apiBehavior, title: "Synthetic source", body: "Unconfirmed behavior",
            sources: [source], changeReason: "Synthetic capture")
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let legacy = try encoder.encode(draft)
        XCTAssertFalse(String(decoding: legacy, as: UTF8.self).contains("knowledgePath"))
        let decoded = try JSONDecoder().decode(MemoryDraft.self, from: legacy)
        XCTAssertEqual(try encoder.encode(decoded), legacy)
        draft.knowledgePath = try XCTUnwrap(KnowledgePath(rawValue: "api/paynet/refunds"))
        let record = MemoryRecord(schemaVersion: 1, scope: scope, id: MemoryID(), revision: 1, supersedes: nil,
            previousFingerprint: nil, createdAt: Date(timeIntervalSinceReferenceDate: 1000), updatedAt: Date(timeIntervalSinceReferenceDate: 1000), content: draft)
        let document = try KnowledgeIndexDocument(memory: record)
        XCTAssertEqual(document.kind, .note); XCTAssertEqual(document.path, draft.knowledgePath)
        XCTAssertEqual(document.fingerprint, try record.fingerprint)
        XCTAssertEqual(document.sourceID, "memory/\(record.id)")
        XCTAssertTrue(document.bodyJSON.contains("interpretation"))
    }
}
