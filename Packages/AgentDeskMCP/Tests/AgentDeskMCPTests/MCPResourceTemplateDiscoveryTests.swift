import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskMCP

final class MCPResourceTemplateDiscoveryTests: XCTestCase {
    private let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
    private let environment = EnvironmentID(), connection = UUID()
    private func decode(_ raw: String, mode: MCPProtocolMode = .legacy) throws -> MCPResourceTemplatePage {
        let message = try MCPMessage(bytes: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(raw)}".utf8))
        return try MCPResourceTemplateDiscovery.decode(message, mode: mode, scope: scope, environmentID: environment, connectionID: connection)
    }
    func testTemplateMetadataScopesAndOpaqueCursorsArePreserved() throws {
        let raw = #"{"resourceTemplates":[{"uriTemplate":"custom:{+path}{?query,fields*}","name":"Evidence","title":"Title","description":"Untrusted","mimeType":"text/plain","_meta":{"precise":9007199254740993}},{"uriTemplate":"{/relative*}","name":"Evidence"}],"nextCursor":"quote\"\n","resultType":"complete","ttlMs":0,"cacheScope":"private"}"#
        let page = try decode(raw, mode: .modern)
        XCTAssertEqual(page.scope, scope); XCTAssertEqual(page.environmentID, environment); XCTAssertEqual(page.connectionID, connection)
        XCTAssertEqual(page.resourceTemplates.first?.uriTemplate, "custom:{+path}{?query,fields*}")
        XCTAssertEqual(page.resourceTemplates.last?.uriTemplate, "{/relative*}")
        XCTAssertEqual(page.resourceTemplates.first?.title, "Title")
        XCTAssertEqual(page.response, Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(raw)}".utf8))
        let params = try JSONSerialization.jsonObject(with: MCPResourceTemplateDiscovery.parameters(mode: .modern, cursor: page.nextCursor)) as? [String: Any]
        XCTAssertEqual(params?["cursor"] as? String, page.nextCursor); XCTAssertNotNil(params?["_meta"])
        XCTAssertEqual(try decode(#"{"resourceTemplates":[]}"#).resourceTemplates, [])
    }
    func testMalformedMetadataAndDuplicateTemplatesAreRejected() throws {
        for raw in [
            #"{"resources":[]}"#,
            #"{"resourceTemplates":[{"uriTemplate":"","name":"x"}]}"#,
            #"{"resourceTemplates":[{"uriTemplate":"urn:bad space","name":"x"}]}"#,
            #"{"resourceTemplates":[{"uriTemplate":"urn:{x}","name":""}]}"#,
            #"{"resourceTemplates":[{"uriTemplate":"urn:{x}","name":"a"},{"uriTemplate":"urn:{x}","name":"b"}]}"#,
            #"{"resourceTemplates":[{"uriTemplate":"urn:{x}","name":"a","mimeType":"bad\nvalue"}]}"#,
            #"{"resourceTemplates":[],"resultType":"input_required"}"#
        ] { XCTAssertThrowsError(try decode(raw)) }
        XCTAssertThrowsError(try decode(#"{"resourceTemplates":[]}"#, mode: .modern))
    }
    func testLimitsAndCancellation() async throws {
        let items = (0..<1001).map { "{\"uriTemplate\":\"urn:\($0){x}\",\"name\":\"x\"}" }.joined(separator: ",")
        XCTAssertThrowsError(try decode("{\"resourceTemplates\":[\(items)]}"))
        XCTAssertThrowsError(try MCPResourceTemplateDiscovery.parameters(mode: .legacy, cursor: String(repeating: "x", count: 4097)))
        let scope = scope, environment = environment, connection = connection
        let message = try MCPMessage(bytes: Data(#"{"jsonrpc":"2.0","id":1,"result":{"resourceTemplates":[]}}"#.utf8))
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try MCPResourceTemplateDiscovery.decode(message, mode: .legacy, scope: scope, environmentID: environment, connectionID: connection)
        }
        do { _ = try await operation.value; XCTFail("Cancelled decode completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
