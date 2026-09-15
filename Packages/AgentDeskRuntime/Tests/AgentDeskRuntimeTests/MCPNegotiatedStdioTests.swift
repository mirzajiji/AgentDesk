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
            elif method == 'prompts/list':
                if mode == 'prompt-stall': continue
                if mode == 'legacy':
                    assert initialized and '_meta' not in r['params']
                else: assert r['params']['_meta']['io.modelcontextprotocol/protocolVersion'] == '2026-07-28'
                cursor = r['params'].get('cursor')
                index = 0 if cursor is None else int(cursor)
                prompt = {'name':str(index),'arguments':[{'name':'context','required':True}]}
                result = {'prompts':[prompt]}
                if mode == 'prompt-duplicate': result['prompts'][0]['name'] = 'duplicate'
                if mode == 'prompt-pages': result['prompts'] = []
                if mode == 'prompt-count': result['prompts'] = [{'name':str(index)+'-'+str(n)} for n in range(200)]
                if mode == 'prompt-bytes': result['prompts'] = [{'name':str(index)+'-'+str(n),'description':'x'*1000} for n in range(50)]
                if mode != 'legacy': result.update({'resultType':'complete','ttlMs':0,'cacheScope':'private'})
                if index == 0 or mode in ['prompt-cycle','prompt-pages','prompt-count','prompt-bytes']:
                    result['nextCursor'] = '1' if mode == 'prompt-cycle' else str(index+1)
            elif method == 'resources/read':
                if mode == 'read-stall': continue
                if mode == 'legacy': assert initialized and '_meta' not in r['params']
                else: assert r['params']['_meta']['io.modelcontextprotocol/protocolVersion'] == '2026-07-28'
                assert r['params']['uri'] == 'custom:collection%2Fone'
                result = {'contents':[{'uri':'urn:part:a','text':'Synthetic text'},{'uri':'urn:part:b','blob':'AP9B'}]}
                if mode != 'legacy': result.update({'resultType':'complete','ttlMs':0,'cacheScope':'private'})
                if mode == 'read-input': result = {'resultType':'input_required'}
                if mode == 'read-malformed': result['contents'][0]['blob'] = 'YQ=='
            elif method == 'resources/list':
                if mode == 'resource-stall': continue
                if mode == 'legacy':
                    assert initialized and '_meta' not in r['params']
                else: assert r['params']['_meta']['io.modelcontextprotocol/protocolVersion'] == '2026-07-28'
                cursor = r['params'].get('cursor')
                index = 0 if cursor is None else int(cursor)
                resource = {'uri':'urn:synthetic:'+str(index),'name':'Evidence','mimeType':'text/plain'}
                result = {'resources':[resource]}
                if mode == 'resource-duplicate': result['resources'][0]['uri'] = 'urn:duplicate'
                if mode == 'resource-pages': result['resources'] = []
                if mode == 'resource-count': result['resources'] = [{'uri':'urn:synthetic:'+str(index)+'-'+str(n),'name':'Evidence'} for n in range(200)]
                if mode == 'resource-bytes': result['resources'] = [{'uri':'urn:synthetic:'+str(index)+'-'+str(n),'name':'Evidence','description':'x'*1000} for n in range(50)]
                if mode != 'legacy': result.update({'resultType':'complete','ttlMs':0,'cacheScope':'private'})
                if index == 0 or mode in ['resource-cycle','resource-pages','resource-count','resource-bytes']:
                    result['nextCursor'] = '1' if mode == 'resource-cycle' else str(index+1)
            elif method == 'tools/list':
                if mode == 'stall': continue
                if mode == 'legacy':
                    assert initialized
                    assert '_meta' not in r['params']
                else: assert r['params']['_meta']['io.modelcontextprotocol/protocolVersion'] == '2026-07-28'
                cursor = r['params'].get('cursor')
                assert cursor is None or cursor == 'opaque cursor'
                result = {'tools':[{'name':'first' if cursor is None else 'second','inputSchema':{'type':'object'}}]}
                if mode != 'legacy': result.update({'resultType':'complete','ttlMs':0,'cacheScope':'private'})
                if cursor is None or mode == 'cycle': result['nextCursor'] = 'opaque cursor'
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
    func testLiveToolPaginationPreservesTransportIdentityAndProtocol() async throws {
        for mode in [MCPProtocolMode.modern, .legacy] {
            let transport = try transport(mode == .modern ? "modern" : "legacy")
            let connection = try await MCPNegotiatedStdioConnection.open(transport: transport, mode: mode)
            do {
                let environment = EnvironmentID()
                let catalog = try await connection.discoverTools(environmentID: environment)
                XCTAssertEqual(catalog.tools.map(\.name), ["first", "second"])
                XCTAssertEqual(catalog.pages.count, 2)
                XCTAssertEqual(catalog.scope, transport.scope)
                XCTAssertEqual(catalog.connectionID, transport.connectionID)
                XCTAssertEqual(catalog.environmentID, environment)
                await connection.close()
            } catch { await connection.close(); throw error }
        }
    }
    func testDiscoveryRejectsCyclesAndTimesOutWithoutPublishingPartialCatalog() async throws {
        for fixture in ["cycle", "stall"] {
            let connection = try await MCPNegotiatedStdioConnection.open(transport: transport(fixture), mode: .modern)
            do {
                _ = try await connection.discoverTools(environmentID: EnvironmentID(), timeout: .milliseconds(100))
                XCTFail("Invalid discovery completed")
            } catch {
                if fixture == "cycle" { XCTAssertEqual(error as? MCPToolPaginationError, .repeatedCursor) }
                else { XCTAssertEqual(error as? MCPRequestError, .timedOut) }
            }
            await connection.close()
        }
    }
    func testCancelledDiscoveryReturnsNoCatalogAndConnectionCanStillPing() async throws {
        let connection = try await MCPNegotiatedStdioConnection.open(transport: transport("modern"), mode: .modern)
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await connection.discoverTools(environmentID: EnvironmentID())
        }
        do { _ = try await operation.value; XCTFail("Cancelled discovery completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await connection.ping() }
        catch { await connection.close(); throw error }
        await connection.close()
    }
    func testLivePromptDiscoveryNegotiatesAndPreservesScope() async throws {
        for mode in [MCPProtocolMode.modern, .legacy] {
            let transport = try transport(mode == .modern ? "modern" : "legacy")
            let connection = try await MCPNegotiatedStdioConnection.open(transport: transport, mode: mode)
            do {
                let environment = EnvironmentID()
                let catalog = try await connection.discoverPrompts(environmentID: environment)
                XCTAssertEqual(catalog.prompts.map(\.name), ["0", "1"])
                XCTAssertEqual(catalog.pages.count, 2)
                XCTAssertEqual(catalog.scope, transport.scope); XCTAssertEqual(catalog.connectionID, transport.connectionID)
                XCTAssertEqual(catalog.environmentID, environment)
                XCTAssertEqual(catalog.prompts.first?.arguments?.first?.required, true)
                await connection.close()
            } catch { await connection.close(); throw error }
        }
    }
    func testPromptTraversalRejectsDuplicateCyclesAndAggregateLimits() async throws {
        for (fixture, expected): (String, MCPPromptTraversalError) in [
            ("prompt-cycle", .repeatedCursor), ("prompt-duplicate", .duplicatePrompt),
            ("prompt-pages", .limitExceeded), ("prompt-count", .limitExceeded), ("prompt-bytes", .limitExceeded)
        ] {
            let connection = try await MCPNegotiatedStdioConnection.open(transport: transport(fixture), mode: .modern)
            do { _ = try await connection.discoverPrompts(environmentID: EnvironmentID()); XCTFail("Unbounded prompt catalog returned") }
            catch { XCTAssertEqual(error as? MCPPromptTraversalError, expected) }
            await connection.close()
        }
    }
    func testStalledPromptDiscoveryTimesOutAndCanBeCancelled() async throws {
        let connection = try await MCPNegotiatedStdioConnection.open(transport: transport("prompt-stall"), mode: .modern)
        do { _ = try await connection.discoverPrompts(environmentID: EnvironmentID(), timeout: .milliseconds(50)); XCTFail("Stalled discovery completed") }
        catch { XCTAssertEqual(error as? MCPRequestError, .timedOut) }
        let operation = Task { try await connection.discoverPrompts(environmentID: EnvironmentID()) }
        try await Task.sleep(for: .milliseconds(30)); operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled discovery completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await connection.ping() }
        catch { await connection.close(); throw error }
        await connection.close()
    }
    func testLiveResourceDiscoveryNegotiatesAndPreservesScope() async throws {
        for mode in [MCPProtocolMode.modern, .legacy] {
            let transport = try transport(mode == .modern ? "modern" : "legacy")
            let connection = try await MCPNegotiatedStdioConnection.open(transport: transport, mode: mode)
            do {
                let environment = EnvironmentID()
                let catalog = try await connection.discoverResources(environmentID: environment)
                XCTAssertEqual(catalog.resources.map(\.uri), ["urn:synthetic:0", "urn:synthetic:1"])
                XCTAssertEqual(catalog.pages.count, 2)
                XCTAssertEqual(catalog.scope, transport.scope); XCTAssertEqual(catalog.connectionID, transport.connectionID)
                XCTAssertEqual(catalog.environmentID, environment)
                XCTAssertEqual(catalog.resources.first?.mimeType, "text/plain")
                await connection.close()
            } catch { await connection.close(); throw error }
        }
    }
    func testResourceTraversalRejectsDuplicateCyclesAndAggregateLimits() async throws {
        for (fixture, expected): (String, MCPResourceTraversalError) in [
            ("resource-cycle", .repeatedCursor), ("resource-duplicate", .duplicateURI),
            ("resource-pages", .limitExceeded), ("resource-count", .limitExceeded), ("resource-bytes", .limitExceeded)
        ] {
            let connection = try await MCPNegotiatedStdioConnection.open(transport: transport(fixture), mode: .modern)
            do { _ = try await connection.discoverResources(environmentID: EnvironmentID()); XCTFail("Unbounded resource catalog returned") }
            catch { XCTAssertEqual(error as? MCPResourceTraversalError, expected) }
            await connection.close()
        }
    }
    func testStalledResourceDiscoveryTimesOutAndCanBeCancelled() async throws {
        let connection = try await MCPNegotiatedStdioConnection.open(transport: transport("resource-stall"), mode: .modern)
        do { _ = try await connection.discoverResources(environmentID: EnvironmentID(), timeout: .milliseconds(50)); XCTFail("Stalled discovery completed") }
        catch { XCTAssertEqual(error as? MCPRequestError, .timedOut) }
        let operation = Task { try await connection.discoverResources(environmentID: EnvironmentID()) }
        try await Task.sleep(for: .milliseconds(30)); operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled discovery completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await connection.ping() }
        catch { await connection.close(); throw error }
        await connection.close()
    }
    func testLiveResourceReadsPreserveRequestIdentityAndBothBodyKinds() async throws {
        for mode in [MCPProtocolMode.modern, .legacy] {
            let transport = try transport(mode == .modern ? "modern" : "legacy")
            let connection = try await MCPNegotiatedStdioConnection.open(transport: transport, mode: mode)
            do {
                let environment = EnvironmentID()
                let result = try await connection.readResource(uri: "custom:collection%2Fone", environmentID: environment)
                XCTAssertEqual(result.scope, transport.scope); XCTAssertEqual(result.connectionID, transport.connectionID)
                XCTAssertEqual(result.environmentID, environment); XCTAssertEqual(result.requestedURI, "custom:collection%2Fone")
                XCTAssertEqual(result.contents.map(\.body), [.text("Synthetic text"), .blob(Data([0, 255, 65]))])
                await connection.close()
            } catch { await connection.close(); throw error }
        }
    }
    func testResourceReadsRejectMalformedContentAndDoNotAnswerInputRequests() async throws {
        for (fixture, expected): (String, MCPResourceReadError) in [("read-malformed", .invalidResponse), ("read-input", .inputRequired)] {
            let connection = try await MCPNegotiatedStdioConnection.open(transport: transport(fixture), mode: .modern)
            do { _ = try await connection.readResource(uri: "custom:collection%2Fone", environmentID: EnvironmentID()); XCTFail("Invalid read completed") }
            catch { XCTAssertEqual(error as? MCPResourceReadError, expected) }
            await connection.close()
        }
    }
    func testResourceReadTimeoutCancellationAndInvalidURIDoNotBreakConnection() async throws {
        let connection = try await MCPNegotiatedStdioConnection.open(transport: transport("read-stall"), mode: .modern)
        do { _ = try await connection.readResource(uri: "relative", environmentID: EnvironmentID()); XCTFail("Invalid URI sent") }
        catch { XCTAssertEqual(error as? MCPResourceReadError, .invalidURI) }
        do { _ = try await connection.readResource(uri: "custom:collection%2Fone", environmentID: EnvironmentID(), timeout: .milliseconds(50)); XCTFail("Stalled read completed") }
        catch { XCTAssertEqual(error as? MCPRequestError, .timedOut) }
        let operation = Task { try await connection.readResource(uri: "custom:collection%2Fone", environmentID: EnvironmentID()) }
        try await Task.sleep(for: .milliseconds(30)); operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled read completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { _ = try await connection.ping() } catch { await connection.close(); throw error }
        await connection.close()
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
