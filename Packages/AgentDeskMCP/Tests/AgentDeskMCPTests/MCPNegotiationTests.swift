import Foundation
import XCTest
@testable import AgentDeskMCP

final class MCPNegotiationTests: XCTestCase {
    private func message(_ result: String) throws -> MCPMessage {
        try MCPMessage(bytes: Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":\(result)}".utf8))
    }
    func testModernAndLegacyDescriptionsDoNotGrantMissingCapabilities() throws {
        let modern = try MCPNegotiation.decode(message(#"{"resultType":"complete","supportedVersions":["2026-07-28"],"capabilities":{"tools":{}},"instructions":"Untrusted instructions"}"#), mode: .modern)
        XCTAssertTrue(modern.tools); XCTAssertFalse(modern.resources); XCTAssertNil(modern.name)
        let legacy = try MCPNegotiation.decode(message(#"{"protocolVersion":"2025-11-25","capabilities":{"resources":{},"prompts":{}},"serverInfo":{"name":"Synthetic","version":"1"}}"#), mode: .legacy)
        XCTAssertFalse(legacy.tools); XCTAssertTrue(legacy.resources); XCTAssertTrue(legacy.prompts)
        XCTAssertEqual(legacy.name, "Synthetic")
        for mode in [MCPProtocolMode.modern, .legacy] {
            XCTAssertNoThrow(try MCPMessage.request(id: .integer(1), method: "ping", params: MCPNegotiation.parameters(for: mode)))
        }
    }
    func testUnsupportedVersionAndMalformedCapabilitiesFail() throws {
        for raw in [#"{"protocolVersion":"unknown","capabilities":{},"serverInfo":{"name":"Synthetic","version":"1"}}"#,
                    #"{"protocolVersion":"2025-11-25","capabilities":{"tools":true},"serverInfo":{"name":"Synthetic","version":"1"}}"#,
                    #"{"protocolVersion":"2025-11-25","capabilities":{}}"#] {
            XCTAssertThrowsError(try MCPNegotiation.decode(message(raw), mode: .legacy))
        }
        XCTAssertThrowsError(try MCPNegotiation.decode(message(#"{"resultType":"complete","supportedVersions":["2025-11-25"],"capabilities":{}}"#), mode: .modern)) {
            XCTAssertEqual($0 as? MCPNegotiationError, .unsupportedVersion)
        }
    }
}
