#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import Foundation
import XCTest
@testable import AgentDeskRuntime

final class MCPNegotiatedStdioTests: XCTestCase {
    private func transport(_ mode: String) throws -> MCPStdioTransport {
        let script = """
        import json, sys
        mode = sys.argv[1]
        initialized = False
        for line in sys.stdin:
            r = json.loads(line)
            if r['method'] == 'notifications/initialized':
                initialized = True
                continue
            if 'id' not in r: continue
            method = r['method']
            if method == 'server/discover':
                assert r['params']['_meta']['io.modelcontextprotocol/protocolVersion'] == '2026-07-28'
                if mode == 'silent': continue
                if mode.startswith('error:'):
                    print(json.dumps({'jsonrpc':'2.0','id':r['id'],'error':{'code':int(mode.split(':')[1]),'message':'Synthetic rejection'}}), flush=True)
                    continue
                result = {'resultType':'complete','supportedVersions':['unknown' if mode == 'bad' else '2026-07-28'],'capabilities':{'tools':{}}}
            elif method == 'initialize':
                assert r['params']['protocolVersion'] == '2025-11-25'
                assert r['params']['capabilities'] == {}
                result = {'protocolVersion':'2025-11-25','capabilities':{},'serverInfo':{'name':'Synthetic','version':'1'}}
            else:
                assert method == 'ping'
                if mode == 'legacy' or mode == 'silent' or mode.startswith('error:'): assert initialized
                else: assert r['params']['_meta']['io.modelcontextprotocol/protocolVersion'] == '2026-07-28'
                result = {}
            print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}), flush=True)
        """
        return try MCPStdioTransport(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), connectionID: UUID(),
            executable: URL(fileURLWithPath: "/usr/bin/python3"), arguments: ["-u", "-c", script, mode], directory: URL(fileURLWithPath: "/tmp"), timeout: .seconds(5))
    }
    func testModernDiscoveryAndLegacyInitializeOrder() async throws {
        for mode in [MCPProtocolMode.modern, .legacy] {
            let connection = try await MCPNegotiatedStdioConnection.open(transport: transport(mode == .modern ? "modern" : "legacy"), mode: mode)
            XCTAssertEqual(connection.server.mode, mode)
            let reply = try await connection.ping(); XCTAssertEqual(reply.kind, .result)
            await connection.close()
        }
    }
    func testAutomaticDetectionAndLegacyFallback() async throws {
        for fixture in ["modern", "error:-32601", "error:-32602", "error:-32001", "silent"] {
            let connection = try await MCPNegotiatedStdioConnection.open(transport: transport(fixture), timeout: .milliseconds(200))
            XCTAssertEqual(connection.server.mode, fixture == "modern" ? .modern : .legacy)
            _ = try await connection.ping()
            await connection.close()
        }
    }
    func testModernRejectionsNeverFallBackToLegacy() async throws {
        for code in [-32020, -32021, -32022] {
            let transport = try transport("error:\(code)")
            do { _ = try await MCPNegotiatedStdioConnection.open(transport: transport); XCTFail("Modern rejection downgraded") }
            catch { XCTAssertEqual(error as? MCPNegotiationError, code == -32022 ? .unsupportedVersion : .invalidResponse) }
            await transport.waitForExit()
        }
    }
    func testVersionMismatchClosesProcess() async throws {
        let transport = try transport("bad")
        do { _ = try await MCPNegotiatedStdioConnection.open(transport: transport, mode: .modern); XCTFail("Unsupported version accepted") }
        catch { XCTAssertEqual(error as? MCPNegotiationError, .unsupportedVersion) }
        await transport.waitForExit()
        do { try await transport.send(.request(id: .integer(1), method: "ping")); XCTFail("Rejected handshake left transport open") }
        catch { XCTAssertEqual(error as? MCPProcessError, .closed) }
    }
}
#endif
