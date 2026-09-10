#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDesk

@MainActor
final class KnowledgeContextPresentationTests: XCTestCase {
    func snapshot(body: String, schema: Int = 1) throws -> String {
        let value: [String: Any] = ["schemaVersion": schema,
            "scope": ["workspaceID": WorkspaceID().rawValue, "projectID": ProjectID().rawValue],
            "environment": EnvironmentID().rawValue, "omittedByLimit": true,
            "entries": [["sourceID": "memory/synthetic", "path": "qa/check", "kind": "note", "revision": 2,
                         "sanitizedFingerprint": "synthetic-hash", "bodyJSON": body]],
            "issues": [["sourceID": "requirement/missing", "reason": "stale-index"]], "relationships": []]
        return String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
    }
    func testReadablePreviewPreservesOriginMultilineValuesExactNumbersAndOmissionWarnings() throws {
        let input = try snapshot(body: #"{"content":{"body":"first line\nsecond line","origin":"interpretation","count":9007199254740993,"verified":false,"nullField":null}}"#)
        let result = try KnowledgeContextPresentation.text(input)
        for expected in ["Note · version 2", "qa/check", "first line", "second line", "interpretation", "9007199254740993",
                         "Verified:", "No", "Null Field:", "Null", "context limit", "requirement/missing: stale index", "Sanitized fingerprint: synthetic-hash"] {
            XCTAssertTrue(result.contains(expected), expected)
        }
        XCTAssertFalse(result.contains("bodyJSON"))
    }
    func testUnsupportedOrMalformedSnapshotsDoNotClaimAFormattedPreview() throws {
        XCTAssertThrowsError(try KnowledgeContextPresentation.text(snapshot(body: "{}", schema: 2)))
        XCTAssertThrowsError(try KnowledgeContextPresentation.text(snapshot(body: "invalid")))
        XCTAssertThrowsError(try KnowledgeContextPresentation.text(String(repeating: "x", count: 32_769)))
    }
}
#endif
