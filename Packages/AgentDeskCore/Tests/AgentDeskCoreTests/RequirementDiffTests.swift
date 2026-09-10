import Foundation
import XCTest
@testable import AgentDeskCore

final class RequirementDiffTests: XCTestCase {
    func testDiffIncludesOnlyChangedFieldsAndPreservesExactValues() throws {
        let original = RequirementDraft(description: "Before", changeReason: "Initial", status: .active)
        var changed = original; changed.description = "After"; changed.changeReason = "New reason"
        let diff = try changed.changes(from: original)
        XCTAssertEqual(diff.map(\.field), ["Description", "Change reason"])
        XCTAssertEqual(diff[0].before, "Before"); XCTAssertEqual(diff[0].after, "After")
        XCTAssertTrue(try original.changes(from: original).isEmpty)
    }
    func testListsCannotHideChangesByNewlineJoiningOrEmptySentinels() throws {
        var original = RequirementDraft(description: "Synthetic", changeReason: "Initial", rules: ["a\nb"])
        var changed = original; changed.rules = ["a", "b"]
        XCTAssertEqual(try changed.changes(from: original).map(\.field), ["Rules"])
        original.rules = []; changed.rules = ["None"]
        XCTAssertEqual(try changed.changes(from: original).map(\.field), ["Rules"])
    }
    func testNewRecordShowsAllContentFieldsIncludingStructuredBehaviorAndScope() throws {
        let draft = RequirementDraft(description: "Synthetic", changeReason: "Initial",
            expectedBehavior: ["values": .array([.boolean(true), .null, .number(Decimal(string: "9007199254740993")!)])],
            environmentScope: [EnvironmentID()])
        let changes = try draft.changes(from: nil)
        XCTAssertEqual(changes.count, 11); XCTAssertTrue(changes.allSatisfy { $0.before == nil })
        XCTAssertTrue(try XCTUnwrap(changes.first { $0.field == "Expected behavior" }).after.contains("9007199254740993"))
        XCTAssertEqual(changes.first { $0.field == "Environment scope" }?.after, draft.environmentScope[0].rawValue)
    }
}
