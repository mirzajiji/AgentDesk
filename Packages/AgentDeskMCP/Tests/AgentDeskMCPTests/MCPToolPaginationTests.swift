import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskMCP

@MainActor final class MCPToolPaginationTests: XCTestCase {
    private let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
    private let environment = EnvironmentID(), connection = UUID()
    private func page(_ name: String, next: String? = nil, foreign: Int = 0) throws -> MCPToolPage {
        var result: [String: Any] = ["tools": [["name": name, "inputSchema": ["type": "object"]]]]
        if let next { result["nextCursor"] = next }
        let message = try MCPMessage(bytes: JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": 1, "result": result]))
        return try MCPToolDiscovery.decode(message, mode: .legacy, scope: ProjectScope(workspaceID: foreign == 2 ? WorkspaceID() : scope.workspaceID, projectID: foreign == 3 ? ProjectID() : scope.projectID), environmentID: foreign == 4 ? EnvironmentID() : environment, connectionID: foreign == 1 ? UUID() : connection)
    }
    private func collector(pages: Int = 100, tools: Int = 10000, bytes: Int = 4_194_304) throws -> MCPToolPagination {
        try MCPToolPagination(scope: scope, environmentID: environment, connectionID: connection, maximumPages: pages, maximumTools: tools, maximumBytes: bytes)
    }
    func testOnlyCompleteScopedCatalogIsPublished() async throws {
        let collector = try collector()
        let first = try page("one", next: ""), second = try page("two")
        try await collector.append(first, requestedCursor: nil)
        let state = await collector.state; XCTAssertEqual(state, .pending(cursor: ""))
        do { _ = try await collector.catalog(); XCTFail("Published incomplete list") }
        catch { XCTAssertEqual(error as? MCPToolPaginationError, .incomplete) }
        try await collector.append(second, requestedCursor: "")
        let catalog = try await collector.catalog()
        XCTAssertEqual(catalog.scope, scope); XCTAssertEqual(catalog.environmentID, environment); XCTAssertEqual(catalog.connectionID, connection)
        XCTAssertEqual(catalog.tools.map(\.name), ["one", "two"])
        XCTAssertEqual(catalog.pages.map(\.response), [first.response, second.response])
        await collector.close()
        do { _ = try await collector.catalog(); XCTFail("Published closed list") } catch { }
    }
    func testRepeatedCursorDuplicateToolWrongCursorAndForeignPageInvalidateTraversal() async throws {
        for mode in 0..<7 {
            let collector = try collector()
            try await collector.append(page("one", next: "next"), requestedCursor: nil)
            do {
                try await collector.append(page(mode == 1 ? "one" : "two", next: mode == 0 ? "next" : nil, foreign: mode >= 3 ? mode - 2 : 0), requestedCursor: mode == 2 ? "wrong" : "next")
                XCTFail("Accepted invalid traversal")
            } catch {
                let expected: [MCPToolPaginationError] = [.repeatedCursor, .duplicateTool, .unexpectedPage, .scopeMismatch, .scopeMismatch, .scopeMismatch, .scopeMismatch]
                XCTAssertEqual(error as? MCPToolPaginationError, expected[mode])
            }
            let state = await collector.state; XCTAssertEqual(state, .closed)
            do { _ = try await collector.catalog(); XCTFail("Published failed traversal") } catch { }
        }
    }
    func testCancelledAppendClosesTraversal() async throws {
        let collector = try collector(), incoming = try page("cancelled")
        let operation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await collector.append(incoming, requestedCursor: nil)
        }
        do { try await operation.value; XCTFail("Cancelled page was accepted") }
        catch { XCTAssertTrue(error is CancellationError) }
        let state = await collector.state; XCTAssertEqual(state, .closed)
        do { _ = try await collector.catalog(); XCTFail("Cancelled traversal published") }
        catch { XCTAssertEqual(error as? MCPToolPaginationError, .closed) }
    }
    func testLimitsAndCursorCycleFailWithoutPartialCatalog() async throws {
        for collector in [try collector(pages: 1), try collector(tools: 1), try collector(bytes: 1)] {
            do {
                try await collector.append(page("one", next: "next"), requestedCursor: nil)
                try await collector.append(page("two"), requestedCursor: "next")
                XCTFail("Exceeded traversal limit")
            } catch { XCTAssertEqual(error as? MCPToolPaginationError, .limitExceeded) }
        }
        let collector = try collector()
        try await collector.append(page("one", next: "a"), requestedCursor: nil)
        try await collector.append(page("two", next: "b"), requestedCursor: "a")
        do { try await collector.append(page("three", next: "a"), requestedCursor: "b"); XCTFail("Accepted cursor cycle") }
        catch { XCTAssertEqual(error as? MCPToolPaginationError, .repeatedCursor) }
    }
}
