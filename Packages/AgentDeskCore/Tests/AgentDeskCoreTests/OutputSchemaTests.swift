import Foundation
import XCTest
@testable import AgentDeskCore

final class OutputSchemaTests: XCTestCase {
    private var schema: OutputSchema {
        .object(["summary": .string(minimum: 1, maximum: 80, choices: nil),
                 "count": .integer(minimum: 0, maximum: 100), "verified": .boolean,
                 "notes": .array(items: .string(minimum: 0, maximum: 20, choices: ["yes", "no"]), minimum: 0, maximum: 2),
                 "missing": .null])
    }
    func testSchemaRoundTripsStandardJSONAndValidatesClosedStructuredOutput() throws {
        let data = try schema.jsonData()
        XCTAssertEqual(try OutputSchema(jsonData: data), schema)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["type"] as? String, "object")
        XCTAssertEqual(object["additionalProperties"] as? Bool, false)
        XCTAssertEqual(Set(object["required"] as? [String] ?? []), ["summary", "count", "verified", "notes", "missing"])
        XCTAssertNoThrow(try schema.validateOutput(#"{"summary":"Synthetic evidence","count":1.0,"verified":true,"notes":["yes"],"missing":null}"#))
        XCTAssertNoThrow(try schema.validateOutput(#"{"summary":"Synthetic evidence","count":1e2,"verified":false,"notes":[],"missing":null}"#))
    }
    func testMissingExtraWrongTypeEnumBoundsAndNullFailWithoutEchoingContent() throws {
        let valid = #"{"summary":"Synthetic evidence","count":1,"verified":true,"notes":["yes"],"missing":null}"#
        let cases = [valid.replacingOccurrences(of: #""count":1,"#, with: ""),
                     valid.replacingOccurrences(of: "{", with: #"{"extra":false,"#),
                     valid.replacingOccurrences(of: #""count":1"#, with: #""count":true"#),
                     valid.replacingOccurrences(of: #""count":1"#, with: #""count":1.1"#),
                     valid.replacingOccurrences(of: #""count":1"#, with: #""count":101"#),
                     valid.replacingOccurrences(of: #""yes""#, with: #""unknown""#),
                     valid.replacingOccurrences(of: #"["yes"]"#, with: #"["yes","no","yes"]"#),
                     valid.replacingOccurrences(of: "null", with: #""null""#)]
        for text in cases { XCTAssertThrowsError(try schema.validateOutput(text)) { XCTAssertEqual($0 as? OutputContractError, .mismatch) } }
    }
    func testMalformedDuplicateKeysDepthAndResourceBoundsFailClosed() throws {
        let anyObject = OutputSchema.object([:])
        for text in ["", "{}{}", "```json\n{}\n```", #"{"x":1,"x":2}"#, #"{"x":1,"\u0078":2}"#,
                     #"{"x":01}"#, #"{"x":+1}"#, #"{"x":NaN}"#, #"{"x":1e999}"#,
                     #"{"x":1e-999}"#, #"{"x":null,}"#, #"{"x":[true,]}"#, #"{"x":"\uD800"}"#,
                     String(repeating: "[", count: 42) + "0" + String(repeating: "]", count: 42)] {
            XCTAssertThrowsError(try anyObject.validateOutput(text)) { XCTAssertEqual($0 as? OutputContractError, .invalidJSON, text) }
        }
        XCTAssertThrowsError(try anyObject.validateOutput("{}", maximumBytes: 1))
        XCTAssertThrowsError(try anyObject.validateOutput(String(repeating: " ", count: 262_145)))
        let tooMany = "[" + Array(repeating: "null", count: 8_193).joined(separator: ",") + "]"
        XCTAssertThrowsError(try OutputJSON.parse(Data(tooMany.utf8)))
    }
    func testUnicodeLengthUsesCodePointsAndEnumUsesExactScalars() throws {
        let one = OutputSchema.string(minimum: 1, maximum: 1, choices: nil)
        XCTAssertNoThrow(try one.validateOutput(#""🧪""#))
        XCTAssertThrowsError(try one.validateOutput("\"e\u{301}\""))
        let exact = OutputSchema.string(minimum: 1, maximum: 3, choices: ["é"])
        XCTAssertNoThrow(try exact.validateOutput("\"é\""))
        XCTAssertThrowsError(try exact.validateOutput("\"e\u{301}\""))
        XCTAssertThrowsError(try one.validateOutput(#""\u0000""#))
    }
    func testUnsupportedLooseAndInvalidSchemasAreRejected() throws {
        for text in [#"{"type":"number"}"#, #"{"type":"object","properties":{},"required":[],"additionalProperties":true}"#,
                     #"{"type":"object","properties":{"x":{"type":"boolean"}},"required":[],"additionalProperties":false}"#,
                     #"{"type":"string","minLength":0,"maxLength":10,"pattern":".*"}"#,
                     #"{"type":"string","minLength":0,"maxLength":10,"enum":null}"#,
                     #"{"type":"boolean","$ref":"file:///unknown"}"#, #"{"type":"boolean","type":"null"}"#] {
            XCTAssertThrowsError(try OutputSchema(jsonData: Data(text.utf8))) { XCTAssertEqual($0 as? OutputContractError, .invalidSchema) }
        }
        for schema in [OutputSchema.array(items: .null, minimum: 2, maximum: 1), .string(minimum: 0, maximum: 65_537, choices: nil),
                       .string(minimum: 0, maximum: 10, choices: []), .integer(minimum: 0, maximum: Int.max), .object(["../escape": .null])] {
            XCTAssertThrowsError(try schema.jsonData())
        }
        var deep = OutputSchema.null
        for _ in 0..<14 { deep = .array(items: deep, minimum: 0, maximum: 1) }
        XCTAssertThrowsError(try deep.validate())
    }
    func testIntegerFractionsAndRangeAreComparedWithoutFloatingPointRounding() throws {
        let integer = OutputSchema.integer(minimum: Int(Int32.min), maximum: Int(Int32.max))
        for number in ["2147483647", "-2147483648", "3.0", "30e-1", "-0"] { XCTAssertNoThrow(try integer.validateOutput(number)) }
        for number in ["2147483648", "-2147483649", "2147483647.000000001", "-0.000000001"] { XCTAssertThrowsError(try integer.validateOutput(number)) }
    }
}
