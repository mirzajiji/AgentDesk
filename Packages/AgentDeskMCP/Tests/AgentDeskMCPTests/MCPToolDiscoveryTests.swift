import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskMCP

final class MCPToolDiscoveryTests: XCTestCase {
    private func message(_ result: String) throws -> MCPMessage {
        try MCPMessage(bytes: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(result)}".utf8))
    }
    private func decode(_ result: String, mode: MCPProtocolMode = .legacy) throws -> MCPToolPage {
        try MCPToolDiscovery.decode(message(result), mode: mode, scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), connectionID: UUID())
    }
    func testMetadataSchemasAndOpaqueCursorArePreservedWithoutGrantingDefaults() throws {
        let raw = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","tools":[{"name":"inspect","title":"Inspect","inputSchema":{"type":"object","$defs":{"large":{"const":9007199254740993}},"oneOf":[{"$ref":"https://example.invalid/schema"}]},"outputSchema":{"type":"string"},"annotations":{"title":"Fallback","readOnlyHint":true}},{"name":"other","inputSchema":{"type":"object"}}],"nextCursor":"quote\"\n\u0000"}"#
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID(), connection = UUID()
        let wire = try message(raw)
        let page = try MCPToolDiscovery.decode(wire, mode: .modern, scope: scope, environmentID: environment, connectionID: connection)
        XCTAssertEqual(page.scope, scope); XCTAssertEqual(page.environmentID, environment); XCTAssertEqual(page.connectionID, connection)
        XCTAssertEqual(page.response, wire.bytes)
        XCTAssertEqual(page.tools.map(\.name), ["inspect", "other"])
        XCTAssertEqual(page.tools.first?.title, "Inspect"); XCTAssertEqual(page.tools.first?.readOnlyHint, true)
        XCTAssertNil(page.tools.last?.readOnlyHint); XCTAssertNil(page.tools.first?.destructiveHint)
        let parameters = try MCPToolDiscovery.parameters(mode: .modern, cursor: page.nextCursor)
        let parsed = try JSONSerialization.jsonObject(with: parameters) as? [String: Any]
        XCTAssertEqual(parsed?["cursor"] as? String, page.nextCursor); XCTAssertNotNil(parsed?["_meta"])
        XCTAssertEqual(try MCPToolDiscovery.parameters(mode: .legacy), Data("{}".utf8))
    }
    func testMalformedAndAmbiguousDefinitionsFailClosed() throws {
        for raw in [
            #"{"tools":[{"name":"x","inputSchema":{"type":"array"}}]}"#,
            #"{"tools":[{"name":"x","inputSchema":{"type":"object"}},{"name":"x","inputSchema":{"type":"object"}}]}"#,
            #"{"tools":[{"name":"x","inputSchema":{"type":"object"},"outputSchema":true}]}"#,
            #"{"tools":[{"name":"x","inputSchema":{"type":"object"},"annotations":{"readOnlyHint":"yes"}}]}"#,
            #"{"tools":[{"name":"","inputSchema":{"type":"object"}}]}"#,
            #"{"tools":[],"resultType":"input_required"}"#
        ] { XCTAssertThrowsError(try decode(raw)) }
        XCTAssertThrowsError(try decode(#"{"tools":[]}"#, mode: .modern))
        XCTAssertThrowsError(try decode(#"{"resultType":"complete","ttlMs":-1,"cacheScope":"private","tools":[]}"#, mode: .modern))
        XCTAssertEqual(try decode(#"{"tools":[]}"#).tools.count, 0)
    }
    func testPageAndCursorLimits() throws {
        let item = #"{"name":"x","inputSchema":{"type":"object"}}"#
        let tools = (0..<1001).map { item.replacingOccurrences(of: "\"x\"", with: "\"x\($0)\"") }.joined(separator: ",")
        XCTAssertThrowsError(try decode("{\"tools\":[\(tools)]}"))
        XCTAssertThrowsError(try MCPToolDiscovery.parameters(mode: .legacy, cursor: String(repeating: "x", count: 4097)))
    }
}
