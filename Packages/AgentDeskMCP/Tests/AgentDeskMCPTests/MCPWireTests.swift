import Foundation
import XCTest
@testable import AgentDeskMCP

final class MCPWireTests: XCTestCase {
    func testFragmentedUTF8AndMultipleFramesPreservePayloadBytes() throws {
        let raw = Data(#"{"jsonrpc":"2.0","id":"one","result":{"name":"ქართული","amount":9007199254740993}}"#.utf8)
        var stream = try MCPLineDecoder()
        var output: [MCPMessage] = []
        for byte in raw + Data([10]) { output += try stream.append(Data([byte])) }
        XCTAssertEqual(output.count, 1); XCTAssertEqual(output[0].bytes, raw)
        XCTAssertEqual(output[0].id, .string("one")); XCTAssertEqual(output[0].kind, .result)
        let two = Data("{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}\n{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"ping\"}\n".utf8)
        let messages = try stream.append(two)
        XCTAssertEqual(messages.map(\.kind), [.notification("notifications/initialized"), .request("ping")])
        XCTAssertEqual(messages[1].id, .integer(42)); try stream.finish()
    }
    func testMalformedEnvelopesAndDuplicateKeysFailClosed() throws {
        for raw in [#"[]"#, #"{"jsonrpc":"1.0","method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":null,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":true,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":1.5,"method":"ping"}"#,
            #"{"jsonrpc":"2.0","id":1,"result":{},"error":{"code":1,"message":"x"}}"#,
            #"{"jsonrpc":"2.0","id":1,"id":2,"result":{}}"#,
            #"{"jsonrpc":"2.0","method":"ping","params":[]}"#,
            #"{"jsonrpc":"2.0","result":{}}"#] {
            var decoder = try MCPLineDecoder()
            XCTAssertThrowsError(try decoder.append(Data((raw + "\n").utf8)), raw)
            XCTAssertThrowsError(try decoder.append(Data())) { XCTAssertEqual($0 as? MCPWireError, .streamClosed) }
        }
        XCTAssertThrowsError(try MCPMessage(bytes: Data([255])))
    }
    func testCancellationClosesStreamAndExactFrameLimitWorks() async throws {
        let operation = Task {
            var stream = try MCPLineDecoder()
            withUnsafeCurrentTask { $0?.cancel() }
            XCTAssertThrowsError(try stream.append(Data())) { XCTAssertTrue($0 is CancellationError) }
            XCTAssertThrowsError(try stream.finish()) { XCTAssertEqual($0 as? MCPWireError, .streamClosed) }
        }
        try await operation.value
        let raw = Data(#"{"jsonrpc":"2.0","method":"ping"}"#.utf8)
        var exact = try MCPLineDecoder(maximumBytes: raw.count)
        XCTAssertEqual(try exact.append(raw + Data([10])).count, 1)
        XCTAssertEqual(try exact.append(raw + Data([10])).count, 1)
        var large = try MCPLineDecoder()
        XCTAssertThrowsError(try large.append(Data(repeating: 32, count: 262_145))) {
            XCTAssertEqual($0 as? MCPWireError, .messageTooLarge)
        }
    }
    func testRequestEncodingPreservesParamsAndEscapesIdentity() throws {
        XCTAssertThrowsError(try MCPMessage.request(id: nil, method: "ping", params: Data(repeating: 32, count: 262_145))) {
            XCTAssertEqual($0 as? MCPWireError, .messageTooLarge)
        }
        XCTAssertThrowsError(try MCPMessage.request(id: .string(String(repeating: "x", count: 1025)), method: "ping"))
        let params = Data(#"{"amount":9007199254740993}"#.utf8)
        let request = try MCPMessage.request(id: .string("quoted\"id"), method: "tools/call", params: params)
        XCTAssertEqual(request.id, .string("quoted\"id")); XCTAssertEqual(request.kind, .request("tools/call"))
        XCTAssertTrue(String(decoding: request.bytes, as: UTF8.self).contains("9007199254740993"))
        XCTAssertEqual(try MCPMessage.request(id: nil, method: "notifications/cancelled").kind, .notification("notifications/cancelled"))
        XCTAssertThrowsError(try MCPMessage.request(id: .integer(1), method: "ping", params: Data("[]".utf8)))
        XCTAssertThrowsError(try MCPMessage.request(id: .integer(1), method: "ping", params: Data("{\n}".utf8)))
    }
    func testLimitsTruncationAndRemoteErrors() throws {
        XCTAssertThrowsError(try MCPLineDecoder(maximumBytes: 0))
        var short = try MCPLineDecoder(maximumBytes: 4)
        XCTAssertThrowsError(try short.append(Data("12345".utf8))) { XCTAssertEqual($0 as? MCPWireError, .messageTooLarge) }
        var truncated = try MCPLineDecoder()
        _ = try truncated.append(Data("{".utf8))
        XCTAssertThrowsError(try truncated.finish()) { XCTAssertEqual($0 as? MCPWireError, .truncatedMessage) }
        let error = try MCPMessage(bytes: Data(#"{"jsonrpc":"2.0","error":{"code":-32700,"message":"Parse error"}}"#.utf8))
        XCTAssertNil(error.id); XCTAssertEqual(error.kind, .error(-32700))
    }
}
