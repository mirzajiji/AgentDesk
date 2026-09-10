#if os(macOS)
import AgentDeskCore
import XCTest
@testable import AgentDesk

@MainActor
final class AgentKnowledgeEditingTests: XCTestCase {
    func testDisabledSelectionAndWhitespaceDoNotBroadenPaths() throws {
        var editing = AgentKnowledgeEditing()
        XCTAssertNil(try editing.selection())
        editing.enabled = true
        XCTAssertEqual(try editing.selection()?.paths.include, [])
        editing.include = "  qa/**  \n\napi/refund\n"
        editing.exclude = "qa/private/**"
        let selection = try XCTUnwrap(editing.selection())
        XCTAssertEqual(selection.paths.include, ["qa/**", "api/refund"])
        XCTAssertFalse(selection.paths.permits(KnowledgePath(rawValue: "qa/private/result")!))
    }
    func testExistingPreferencesAndRelationshipsSurviveEditorRoundTrip() throws {
        let original = try AgentKnowledgeSelection(paths: .init(include: ["requirements/**"], exclude: ["requirements/private"]),
            query: "refund", kinds: [.requirement, .note], maximumRecords: 5, maximumBytes: 8_192,
            relationships: [.init(kind: .automatedTest, id: RequirementID(rawValue: "refund-test")!)])
        XCTAssertEqual(try AgentKnowledgeEditing(original).selection(), original)
    }
    func testInvalidPathsAndRelationshipSyntaxCannotBeSaved() throws {
        var editing = AgentKnowledgeEditing(); editing.enabled = true
        for text in ["../private", "/company", "qa/*/x"] {
            editing.include = text; XCTAssertThrowsError(try editing.selection())
        }
        editing.include = "qa/**"
        for text in ["shell/run", "bug/../private", "bug/", "bug/UPPER"] {
            editing.relationships = text; XCTAssertThrowsError(try editing.selection())
        }
        editing.relationships = ""; editing.requirements = false; editing.confirmed = false
        XCTAssertThrowsError(try editing.selection())
    }
}
#endif
