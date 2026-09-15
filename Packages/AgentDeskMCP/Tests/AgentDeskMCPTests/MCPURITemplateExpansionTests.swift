import Foundation
import XCTest
@testable import AgentDeskMCP

final class MCPURITemplateExpansionTests: XCTestCase {
    func testScalarOperatorsEncodingAndUndefinedValues() throws {
        let values: [String: MCPURITemplateValue] = ["x": .string("1024"), "y": .string("768"), "path": .string("/foo/bar"), "empty": .string(""), "word": .string("Hello World!")]
        for (source, expected) in ["{word}": "Hello%20World%21", "{+path}/here": "/foo/bar/here", "{#path}": "#/foo/bar", "{.x,y}": ".1024.768", "{/x,y}": "/1024/768", "{;x,empty,missing}": ";x=1024;empty", "{?x,y,empty,missing}": "?x=1024&y=768&empty=", "{&x}": "&x=1024", "{missing}": ""] {
            XCTAssertEqual(try MCPURITemplate(source).expand(values), expected, source)
        }
        XCTAssertEqual(try MCPURITemplate("é/%2f/{x}").expand(["x": .string("%2f")]), "%C3%A9/%2f/%252f")
        XCTAssertEqual(try MCPURITemplate("{+x}").expand(["x": .string("%2f%ZZ")]), "%2f%25ZZ")
    }
    func testCompositeExpansionAndPrefixRules() throws {
        let values: [String: MCPURITemplateValue] = ["list": .list(["red", "green", "blue"]), "keys": .associative(["a": "1", "b": ""])]
        for (source, expected) in ["{list}": "red,green,blue", "{/list*}": "/red/green/blue", "{?list*}": "?list=red&list=green&list=blue", "{keys}": "a,1,b,", "{?keys*}": "?a=1&b=", "{;keys*}": ";a=1;b"] {
            XCTAssertEqual(try MCPURITemplate(source).expand(values), expected, source)
        }
        XCTAssertThrowsError(try MCPURITemplate("{list:2}").expand(values))
        XCTAssertEqual(try MCPURITemplate("{?list,keys}").expand(["list": .list([]), "keys": .associative([:])]), "")
        XCTAssertEqual(try MCPURITemplate("{x:1}").expand(["x": .string("éx")]), "%C3%A9")
        XCTAssertEqual(try MCPURITemplate("{+x:1}").expand(["x": .string("%C3%A9x")]), "%C3%A9")
    }
    func testBoundsAndCancellation() async throws {
        XCTAssertThrowsError(try MCPURITemplate("{x}").expand(["x": .string(String(repeating: "a", count: 65537))]))
        XCTAssertThrowsError(try MCPURITemplate("{x}{x}").expand(["x": .string(String(repeating: "?", count: 20000))]))
        XCTAssertThrowsError(try MCPURITemplate("{x}").expand([String(repeating: "a", count: 65537): .list([])]))
        XCTAssertThrowsError(try MCPURITemplate("{x}").expand(["x": .list(Array(repeating: "", count: 1025))]))
        let template = try MCPURITemplate("{x}")
        let task = Task { withUnsafeCurrentTask { $0?.cancel() }; return try template.expand(["x": .string("a")]) }
        do { _ = try await task.value; XCTFail("Cancelled expansion succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
