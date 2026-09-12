#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import Foundation
import XCTest
@testable import AgentDeskRuntime

final class MCPStdioTransportTests: XCTestCase {
    private func transport(_ executable: String = "/bin/cat", arguments: [String] = [], timeout: Duration = .seconds(5)) throws -> MCPStdioTransport {
        try MCPStdioTransport(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), connectionID: UUID(),
            executable: URL(fileURLWithPath: executable), arguments: arguments, directory: URL(fileURLWithPath: "/tmp"), timeout: timeout)
    }
    func testRealPipeRoundTripAndGracefulEOF() async throws {
        let transport = try transport()
        let message = try MCPMessage(bytes: Data(#"{"jsonrpc":"2.0","id":1,"method":"ping"}"#.utf8))
        try await transport.send(message); await transport.finishInput()
        var received: [MCPMessage] = []
        for try await frame in transport.messages { received.append(frame) }
        XCTAssertEqual(received.count, 1); XCTAssertEqual(received.first?.bytes, message.bytes)
        do { try await transport.send(message); XCTFail("Closed stdin accepted a message") }
        catch { XCTAssertEqual(error as? MCPProcessError, .closed) }
        await transport.close()
    }
    func testMalformedOutputAndTimeoutTerminateTransport() async throws {
        let malformed = try transport("/bin/echo", arguments: ["not-json"])
        do { for try await _ in malformed.messages { XCTFail("Malformed frame delivered") }; XCTFail("Malformed output accepted") }
        catch { XCTAssertEqual(error as? MCPWireError, .malformedMessage) }
        await malformed.close()
        let idle = try transport(timeout: .milliseconds(40))
        do { for try await _ in idle.messages {}; XCTFail("Idle server never timed out") }
        catch { XCTAssertEqual(error as? MCPProcessError, .timedOut) }
        await idle.close()
    }
    func testReceiveOverflowFailsInsteadOfDroppingMessagesSilently() async throws {
        let line = #"{"jsonrpc":"2.0","method":"ping"}"# + "\n"
        let transport = try transport("/usr/bin/printf", arguments: [String(repeating: line, count: 129)])
        await transport.waitForExit()
        var count = 0
        do { for try await _ in transport.messages { count += 1 }; XCTFail("Overflow silently succeeded") }
        catch { XCTAssertEqual(error as? MCPProcessError, .receiveOverflow) }
        XCTAssertEqual(count, 128)
        await transport.close()
    }
    func testConsumerCancellationStopsOwnedProcess() async throws {
        let transport = try transport()
        let start = ContinuousClock.now
        let reader = Task { for try await _ in transport.messages {} }
        reader.cancel()
        _ = try? await reader.value
        await transport.waitForExit()
        XCTAssertLessThan(start.duration(to: .now), .seconds(2), "Must cancel before the five-second process timeout")
        await transport.close()
    }
    func testCancellationAndMultilineSendRejection() async throws {
        let transport = try transport()
        let pretty = try MCPMessage(bytes: Data("{\n\"jsonrpc\":\"2.0\",\"method\":\"ping\"}".utf8))
        do { try await transport.send(pretty); XCTFail("Multiline wire message accepted") }
        catch { XCTAssertEqual(error as? MCPProcessError, .invalidFrame) }
        await transport.close()
        do { for try await _ in transport.messages {}; XCTFail("Cancellation not delivered") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
#endif
