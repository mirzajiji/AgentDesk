import Foundation
import XCTest
@testable import AgentDeskMCP

final class MCPURITemplateTests: XCTestCase {
    func testAllOperatorsModifiersAndOpaqueVariableNames() throws {
        let source = "custom:é/%2f/{var}{+path}{#fragment}{.labels*}{/segments*}{;x,y}{?x:4,y:9999}{&%61,a.b,a_b}"
        let template = try MCPURITemplate(source)
        XCTAssertEqual(template.source, source)
        XCTAssertEqual(template.variableNames, ["var", "path", "fragment", "labels", "segments", "x", "y", "%61", "a.b", "a_b"])
        guard case .expression("?", let vars) = template.segments[7] else { return XCTFail("Missing query expression") }
        XCTAssertEqual(vars.map(\.prefix), [4, 9999]); XCTAssertFalse(vars[0].explode)
        XCTAssertTrue(try MCPURITemplate("").segments.isEmpty)
        XCTAssertEqual(try MCPURITemplate("{a,%61,a}").variableNames, ["a", "%61"])
    }
    func testInvalidSyntaxAndReservedOperatorsFail() throws {
        for source in ["{", "}", "{}", "{{x}}", "{x,}", "{,x}", "{x,,y}", "{x\n}", "{x:2\n}", "\u{E0001}", "{x:0}", "{x:01}", "{x:10000}", "{x:2*}", "{x**}", "{x.}", "{x..y}", "{é}", "{a-b}", "%", "%ZZ", "{x%2}", "a b", "a\\b", "a'b", "a\n", "\u{FFFF}"] {
            XCTAssertThrowsError(try MCPURITemplate(source), source)
        }
        for op in ["=", "!", "@", "|"] {
            XCTAssertThrowsError(try MCPURITemplate("{\(op)x}")) { XCTAssertEqual($0 as? MCPURITemplateError, .unsupportedOperator) }
        }
    }
    func testBoundsAndCancellation() async throws {
        XCTAssertThrowsError(try MCPURITemplate(String(repeating: "x", count: 4097)))
        XCTAssertThrowsError(try MCPURITemplate(String(repeating: "{x}", count: 129)))
        XCTAssertThrowsError(try MCPURITemplate("{" + Array(repeating: "x", count: 257).joined(separator: ",") + "}"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MCPURITemplate("{x}")
        }
        do { _ = try await task.value; XCTFail("Cancelled parsing succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
