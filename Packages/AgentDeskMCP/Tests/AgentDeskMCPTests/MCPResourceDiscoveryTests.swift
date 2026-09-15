import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskMCP

final class MCPResourceDiscoveryTests: XCTestCase {
    private let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
    private let environment = EnvironmentID(), connection = UUID()
    private func decode(_ raw: String, mode: MCPProtocolMode = .legacy) throws -> MCPResourcePage {
        let message = try MCPMessage(bytes: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(raw)}".utf8))
        return try MCPResourceDiscovery.decode(message, mode: mode, scope: scope, environmentID: environment, connectionID: connection)
    }
    func testOpaqueURIsScopesAndExactLargeSizesArePreserved() throws {
        let raw = #"{"resources":[{"uri":"custom://project/path%2Fpart?x=1","name":"Evidence","title":"Title","description":"Untrusted metadata","mimeType":"text/plain","size":9007199254740993,"annotations":{"priority":0.5}},{"uri":"urn:synthetic:resource","name":"Evidence"}],"nextCursor":"quote\"\n","resultType":"complete","ttlMs":0,"cacheScope":"private"}"#
        let page = try decode(raw, mode: .modern)
        XCTAssertEqual(page.scope, scope); XCTAssertEqual(page.environmentID, environment); XCTAssertEqual(page.connectionID, connection)
        XCTAssertEqual(page.resources.first?.uri, "custom://project/path%2Fpart?x=1")
        XCTAssertEqual(page.resources.first?.size, 9_007_199_254_740_993)
        XCTAssertEqual(page.resources.last?.uri, "urn:synthetic:resource"); XCTAssertNil(page.resources.last?.size)
        XCTAssertEqual(page.response, Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(raw)}".utf8))
        let params = try JSONSerialization.jsonObject(with: MCPResourceDiscovery.parameters(mode: .modern, cursor: page.nextCursor)) as? [String: Any]
        XCTAssertEqual(params?["cursor"] as? String, page.nextCursor); XCTAssertNotNil(params?["_meta"])
        XCTAssertEqual(try decode(#"{"resources":[]}"#).resources, [])
    }
    func testMalformedURIsDuplicatesAndSizesAreRejected() throws {
        for raw in [
            #"{"resources":[{"uri":"relative/path","name":"x"}]}"#,
            #"{"resources":[{"uri":"custom:bad space","name":"x"}]}"#,
            #"{"resources":[{"uri":"custom:%ZZ","name":"x"}]}"#,
            #"{"resources":[{"uri":"urn:x","name":""}]}"#,
            #"{"resources":[{"uri":"urn:x","name":"a"},{"uri":"urn:x","name":"b"}]}"#,
            #"{"resources":[{"uri":"urn:x","name":"a","size":-1}]}"#,
            #"{"resources":[{"uri":"urn:x","name":"a","size":1.5}]}"#,
            #"{"resources":[{"uri":"urn:x","name":"a","mimeType":"bad\nvalue"}]}"#,
            #"{"resources":[],"resultType":"input_required"}"#
        ] { XCTAssertThrowsError(try decode(raw)) }
        XCTAssertThrowsError(try decode(#"{"resources":[]}"#, mode: .modern))
    }
    func testPageLimitsAndCancelledDecode() async throws {
        let resources = (0..<1001).map { "{\"uri\":\"urn:\($0)\",\"name\":\"x\"}" }.joined(separator: ",")
        XCTAssertThrowsError(try decode("{\"resources\":[\(resources)]}"))
        XCTAssertThrowsError(try MCPResourceDiscovery.parameters(mode: .legacy, cursor: String(repeating: "x", count: 4097)))
        let scope = scope, environment = environment, connection = connection
        let message = try MCPMessage(bytes: Data(#"{"jsonrpc":"2.0","id":1,"result":{"resources":[]}}"#.utf8))
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MCPResourceDiscovery.decode(message, mode: .legacy, scope: scope, environmentID: environment, connectionID: connection)
        }
        do { _ = try await operation.value; XCTFail("Cancelled resource decode completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
