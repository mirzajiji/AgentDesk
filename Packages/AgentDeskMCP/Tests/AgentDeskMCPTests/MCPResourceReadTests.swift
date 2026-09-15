import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskMCP

final class MCPResourceReadTests: XCTestCase {
    private let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
    private let environment = EnvironmentID(), connection = UUID()
    private func message(_ result: String) throws -> MCPMessage {
        try MCPMessage(bytes: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(result)}".utf8))
    }
    private func decode(_ raw: String, mode: MCPProtocolMode = .legacy) throws -> MCPResourceReadResult {
        try MCPResourceRead.decode(message(raw), mode: mode, requestedURI: "custom:collection%2Fone", scope: scope,
            environmentID: environment, connectionID: connection)
    }
    func testTextAndBinaryContentPreserveRequestedIdentityAndRawEvidence() throws {
        let raw = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","contents":[{"uri":"urn:part:a","mimeType":"text/plain","text":"Hello\n世界"},{"uri":"urn:part:b","blob":"AP9B"}],"_meta":{"large":9007199254740993}}"#
        let result = try decode(raw, mode: .modern)
        XCTAssertEqual(result.scope, scope); XCTAssertEqual(result.environmentID, environment); XCTAssertEqual(result.connectionID, connection)
        XCTAssertEqual(result.requestedURI, "custom:collection%2Fone")
        XCTAssertEqual(result.contents.map(\.uri), ["urn:part:a", "urn:part:b"])
        XCTAssertEqual(result.contents.first?.body, .text("Hello\n世界"))
        XCTAssertEqual(result.contents.last?.body, .blob(Data([0, 255, 65])))
        XCTAssertEqual(result.response, try message(raw).bytes)
        let params = try JSONSerialization.jsonObject(with: MCPResourceRead.parameters(mode: .modern, uri: result.requestedURI)) as? [String: Any]
        XCTAssertEqual(params?["uri"] as? String, result.requestedURI); XCTAssertNotNil(params?["_meta"])
        XCTAssertEqual(try decode(#"{"contents":[]}"#).contents, [])
    }
    func testAmbiguousMalformedAndUnsupportedBodiesFailClosed() throws {
        for raw in [
            #"{"contents":[{"uri":"urn:x"}]}"#,
            #"{"contents":[{"uri":"urn:x","text":"a","blob":"YQ=="}]}"#,
            #"{"contents":[{"uri":"urn:x","text":"a","blob":null}]}"#,
            #"{"contents":[{"uri":"urn:x","text":null}]}"#,
            #"{"contents":[{"uri":"urn:x","blob":"YQ"}]}"#,
            #"{"contents":[{"uri":"urn:x","blob":"@@@="}]}"#,
            #"{"contents":[{"uri":"relative/path","text":"x"}]}"#,
            #"{"contents":[{"uri":"urn:x","mimeType":"bad\nvalue","text":"x"}]}"#
        ] { XCTAssertThrowsError(try decode(raw)) }
        XCTAssertThrowsError(try decode(#"{"contents":[]}"#, mode: .modern))
        XCTAssertThrowsError(try MCPResourceRead.parameters(mode: .legacy, uri: "bad uri"))
        XCTAssertThrowsError(try decode(#"{"resultType":"input_required"}"#, mode: .modern)) {
            XCTAssertEqual($0 as? MCPResourceReadError, .inputRequired)
        }
    }
    func testAggregateLimitsAndCancellation() async throws {
        let many = Array(repeating: #"{"uri":"urn:x","text":""}"#, count: 129).joined(separator: ",")
        XCTAssertThrowsError(try decode("{\"contents\":[\(many)]}")) { XCTAssertEqual($0 as? MCPResourceReadError, .sizeLimit) }
        let text = String(repeating: "a", count: 100_000)
        XCTAssertThrowsError(try decode("{\"contents\":[{\"uri\":\"urn:a\",\"text\":\"\(text)\"},{\"uri\":\"urn:b\",\"text\":\"\(text)\"}]}")) {
            XCTAssertEqual($0 as? MCPResourceReadError, .sizeLimit)
        }
        let scope = scope, environment = environment, connection = connection, message = try message(#"{"contents":[]}"#)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MCPResourceRead.decode(message, mode: .legacy, requestedURI: "urn:x", scope: scope, environmentID: environment, connectionID: connection)
        }
        do { _ = try await operation.value; XCTFail("Cancelled read decoding completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
