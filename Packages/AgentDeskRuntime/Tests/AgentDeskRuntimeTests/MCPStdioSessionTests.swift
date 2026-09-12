#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import Foundation
import XCTest
@testable import AgentDeskRuntime

final class MCPStdioSessionTests: XCTestCase {
    private func session() throws -> MCPStdioSession {
        let script = """
        import json, sys
        for line in sys.stdin:
            request = json.loads(line)
            if 'id' not in request: continue
            if request['method'] == 'hold': continue
            if request['method'] == 'exit': sys.exit(0)
            print(json.dumps({'jsonrpc':'2.0','id':request['id'],'result':request['params']}), flush=True)
        """
        let transport = try MCPStdioTransport(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), connectionID: UUID(),
            executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script], directory: URL(fileURLWithPath: "/tmp"), timeout: .seconds(5))
        return try MCPStdioSession(transport: transport)
    }
    func testRealProcessResponsesReachMatchingCallers() async throws {
        let session = try session()
        async let first = session.request(method: "ping", params: Data(#"{"marker":"first"}"#.utf8))
        async let second = session.request(method: "ping", params: Data(#"{"marker":"second"}"#.utf8))
        let (a, b) = try await (first, second)
        XCTAssertEqual(a.kind, .result); XCTAssertEqual(b.kind, .result); XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(String(decoding: a.bytes, as: UTF8.self).contains("first"))
        XCTAssertTrue(String(decoding: b.bytes, as: UTF8.self).contains("second"))
        await session.close()
    }
    func testTimeoutAndCancellationLeaveOtherRequestsUsable() async throws {
        let session = try session()
        do { _ = try await session.request(method: "hold", timeout: .milliseconds(30)); XCTFail("No timeout") }
        catch { XCTAssertEqual(error as? MCPRequestError, .timedOut) }
        let held = Task { try await session.request(method: "hold") }
        try await Task.sleep(for: .milliseconds(20)); held.cancel()
        do { _ = try await held.value; XCTFail("No cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        let result = try await session.request(method: "ping")
        XCTAssertEqual(result.kind, .result)
        await session.close()
    }
    func testProcessExitAndExplicitCloseReleasePendingCalls() async throws {
        let session = try session()
        do { _ = try await session.request(method: "exit"); XCTFail("Exit left request successful") }
        catch { XCTAssertEqual(error as? MCPProcessError, .closed) }
        await session.close()
        let other = try self.session()
        let held = Task { try await other.request(method: "hold") }
        try await Task.sleep(for: .milliseconds(20)); await other.close()
        do { _ = try await held.value; XCTFail("Closed waiter succeeded") }
        catch { XCTAssertEqual(error as? MCPProcessError, .closed) }
    }
}
#endif
