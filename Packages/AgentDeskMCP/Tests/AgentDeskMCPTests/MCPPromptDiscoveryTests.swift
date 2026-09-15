import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskMCP

final class MCPPromptDiscoveryTests: XCTestCase {
    private let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
    private let environment = EnvironmentID(), connection = UUID()
    private func decode(_ raw: String, mode: MCPProtocolMode = .legacy) throws -> MCPPromptPage {
        let message = try MCPMessage(bytes: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(raw)}".utf8))
        return try MCPPromptDiscovery.decode(message, mode: mode, scope: scope, environmentID: environment, connectionID: connection)
    }
    func testScopedMetadataArgumentsAndUnknownEvidenceArePreserved() throws {
        let raw = #"{"resultType":"complete","ttlMs":0,"cacheScope":"private","prompts":[{"name":"review","title":"Review","description":"Untrusted instructions","arguments":[{"name":"change","title":"Change","description":"Change to review","required":true},{"name":"context"}],"_meta":{"number":9007199254740993}}],"nextCursor":"quote\"\n"}"#
        let page = try decode(raw, mode: .modern)
        XCTAssertEqual(page.scope, scope); XCTAssertEqual(page.environmentID, environment); XCTAssertEqual(page.connectionID, connection)
        XCTAssertTrue(String(decoding: page.response, as: UTF8.self).contains("9007199254740993"))
        XCTAssertEqual(page.prompts.first?.title, "Review")
        XCTAssertEqual(page.prompts.first?.arguments?.first?.required, true)
        XCTAssertNil(page.prompts.first?.arguments?.last?.required)
        let params = try JSONSerialization.jsonObject(with: MCPPromptDiscovery.parameters(mode: .modern, cursor: page.nextCursor)) as? [String: Any]
        XCTAssertEqual(params?["cursor"] as? String, page.nextCursor); XCTAssertNotNil(params?["_meta"])
        XCTAssertEqual(try decode(#"{"prompts":[]}"#).prompts, [])
    }
    func testMalformedPromptAndArgumentDefinitionsAreRejected() throws {
        for raw in [
            #"{"prompts":[{"name":""}]}"#,
            #"{"prompts":[{"name":"x"},{"name":"x"}]}"#,
            #"{"prompts":[{"name":"x","arguments":[{"name":"a"},{"name":"a"}]}]}"#,
            #"{"prompts":[{"name":"x","arguments":[{"name":"a","required":"true"}]}]}"#,
            #"{"prompts":[{"name":"x","title":"bad\n"}]}"#,
            #"{"prompts":[{"name":"x","arguments":[{"name":"\u0000"}]}]}"#,
            #"{"prompts":[],"resultType":"input_required"}"#
        ] { XCTAssertThrowsError(try decode(raw)) }
        XCTAssertThrowsError(try decode(#"{"prompts":[]}"#, mode: .modern))
        XCTAssertThrowsError(try decode(#"{"prompts":[],"resultType":"complete","ttlMs":-1,"cacheScope":"private"}"#, mode: .modern))
    }
    func testBoundsAndCancellationFailClosed() async throws {
        let arguments = (0..<129).map { "{\"name\":\"a\($0)\"}" }.joined(separator: ",")
        XCTAssertThrowsError(try decode("{\"prompts\":[{\"name\":\"x\",\"arguments\":[\(arguments)]}]}"))
        let prompts = (0..<1001).map { "{\"name\":\"p\($0)\"}" }.joined(separator: ",")
        XCTAssertThrowsError(try decode("{\"prompts\":[\(prompts)]}"))
        XCTAssertThrowsError(try MCPPromptDiscovery.parameters(mode: .legacy, cursor: String(repeating: "x", count: 4097)))
        let scope = scope, environment = environment, connection = connection
        let operation = Task {
            let message = try MCPMessage(bytes: Data(#"{"jsonrpc":"2.0","id":1,"result":{"prompts":[]}}"#.utf8))
            withUnsafeCurrentTask { $0?.cancel() }
            return try MCPPromptDiscovery.decode(message, mode: .legacy, scope: scope, environmentID: environment, connectionID: connection)
        }
        do { _ = try await operation.value; XCTFail("Cancelled parsing completed") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
