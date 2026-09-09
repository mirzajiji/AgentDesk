import Foundation
import XCTest
@testable import AgentDeskRuntime

final class CodexRPCWireTests: XCTestCase {
    func testSplitUTF8CRLFAndFinalRecordPreserveExactMessages() throws {
        let messages = [Data("{\"text\":\"🧪\"}".utf8), Data("{\"id\":2}".utf8)]
        let stream = messages[0] + Data([13, 10, 10]) + messages[1]
        var framer = try CodexJSONLineFramer(), result: [Data] = []
        for byte in stream { result += try framer.append(Data([byte])) }
        result += try framer.finish()
        XCTAssertEqual(result, messages)
        XCTAssertEqual(try CodexJSONValue.decodeMessage(result[0])["text"]?.string, "🧪")
        XCTAssertThrowsError(try framer.append(Data()))
    }
    func testFramingAndJSONRejectOversizeMalformedDeepOrNonobjectRecords() throws {
        var small = try CodexJSONLineFramer(maximumRecordBytes: 4)
        XCTAssertThrowsError(try small.append(Data("12345".utf8)))
        var invalidUTF8 = try CodexJSONLineFramer()
        XCTAssertThrowsError(try invalidUTF8.append(Data([0xff, 10])))
        XCTAssertThrowsError(try CodexJSONValue.decodeMessage(Data([123, 125, 0])))
        XCTAssertThrowsError(try CodexJSONValue.decodeMessage(Data([123, 34, 120, 34, 58, 34, 255, 34, 125])))
        for text in ["{", "[1,2]", "null", "{\"data\":" + String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40) + "}"] {
            XCTAssertThrowsError(try CodexJSONValue.decodeMessage(Data(text.utf8)))
        }
    }
    func testTypedWireRoundTripKeepsLiteralContentAndBooleansDistinctFromIntegers() throws {
        let value = CodexJSONValue.object(["id": .integer(3), "method": .string("turn/start"),
            "params": .object(["input": .string("$(echo nope); `literal`\n🧪"), "ephemeral": .bool(true), "optional": .null])])
        let decoded = try CodexJSONValue.decodeMessage(value.line())
        XCTAssertEqual(decoded, value.object)
        XCTAssertNil(decoded["params"]?["ephemeral"]?.integer)
        XCTAssertNil(decoded["id"]?.bool)
    }
}
