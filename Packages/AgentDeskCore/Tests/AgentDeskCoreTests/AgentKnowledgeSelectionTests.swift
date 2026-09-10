import Foundation
import XCTest
@testable import AgentDeskCore

final class AgentKnowledgeSelectionTests: XCTestCase {
    func testLegacyProfileDoesNotEnableRetrievalOrChangeCanonicalEncoding() throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(CodexAgentProfile())
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("knowledge"))
        let profile = try JSONDecoder().decode(CodexAgentProfile.self, from: data)
        XCTAssertNil(profile.knowledge)
        XCTAssertEqual(try encoder.encode(profile), data)
    }

    func testSelectionRoundTripsAndExclusionsWinWithoutImplicitUncertainKnowledge() throws {
        let selection = try AgentKnowledgeSelection(paths: .init(include: ["api/**"], exclude: ["api/private/**"]),
            query: "refund", relationships: [.init(kind: .automatedTest, id: RequirementID(rawValue: "refund-test")!)])
        let profile = CodexAgentProfile(knowledge: selection)
        let copy = try JSONDecoder().decode(CodexAgentProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(copy, profile)
        XCTAssertEqual(Set(selection.kinds), [.requirement, .confirmed])
        XCTAssertTrue(selection.paths.permits(KnowledgePath(rawValue: "api/refund")!))
        XCTAssertFalse(selection.paths.permits(KnowledgePath(rawValue: "api/private/refund")!))
        let empty = try AgentKnowledgeSelection(paths: .init(include: []))
        XCTAssertFalse(empty.paths.permits(KnowledgePath(rawValue: "api/refund")!))
    }

    func testMalformedDecodedSelectionsCannotBypassValidation() throws {
        let original = try AgentKnowledgeSelection(paths: .init(include: ["qa/**"]))
        let bytes = try JSONEncoder().encode(original)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        let invalid: [(String, Any)] = [
            ("maximumRecords", 0), ("maximumRecords", 33), ("maximumBytes", 32_769),
            ("query", String(repeating: "x ", count: 17)), ("kinds", ["confirmed", "confirmed"]),
            ("kinds", []), ("paths", ["include": ["../private"], "exclude": []]),
            ("paths", ["include": ["**"]]), ("paths", ["include": ["**"], "exclude": [], "deny": ["private/**"]]), ("unknownAuthority", true)
        ]
        for (key, value) in invalid {
            var changed = object; changed[key] = value
            let input = try JSONSerialization.data(withJSONObject: changed)
            XCTAssertThrowsError(try JSONDecoder().decode(AgentKnowledgeSelection.self, from: input), key)
        }
    }
}
