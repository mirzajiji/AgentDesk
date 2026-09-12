import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskMCP

final class MCPRequestTrackerTests: XCTestCase {
    private func tracker(limit: Int = 128) throws -> MCPRequestTracker {
        try MCPRequestTracker(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), connectionID: UUID(), maximumPending: limit)
    }
    private func response(_ id: MCPRequestID, error: Bool = false) throws -> MCPMessage {
        guard case .string(let value) = id else { throw MCPRequestError.invalidRequest }
        let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        let payload = error ? #""error":{"code":-32601,"message":"Synthetic"}"# : #""result":{}"#
        return try MCPMessage(bytes: Data("{\"jsonrpc\":\"2.0\",\"id\":\(encoded),\(payload)}".utf8))
    }
    func testOutOfOrderResponsesAndDuplicateRejection() async throws {
        let tracker = try tracker()
        let first = try await tracker.begin(method: "ping", timeout: .seconds(10))
        let second = try await tracker.begin(method: "tools/list", timeout: .seconds(10))
        let completedSecond = try await tracker.complete(response(second.id, error: true))
        let completedFirst = try await tracker.complete(response(first.id))
        XCTAssertEqual(completedSecond, second); XCTAssertEqual(completedFirst, first)
        XCTAssertEqual(first.scope, tracker.scope); XCTAssertEqual(first.connectionID, tracker.connectionID)
        do { _ = try await tracker.complete(response(first.id)); XCTFail("Duplicate completed") }
        catch { XCTAssertEqual(error as? MCPRequestError, .unexpectedResponse) }
    }
    func testCancellationTimeoutAndCapacityRelease() async throws {
        let tracker = try tracker(limit: 1), now = ContinuousClock.now
        let first = try await tracker.begin(method: "ping", timeout: .seconds(1), now: now)
        do { _ = try await tracker.begin(method: "ping", timeout: .seconds(1)); XCTFail("Unbounded requests") }
        catch { XCTAssertEqual(error as? MCPRequestError, .capacityExceeded) }
        let cancelled = await tracker.cancel(first.id); XCTAssertEqual(cancelled, first)
        do { _ = try await tracker.complete(response(first.id)); XCTFail("Cancelled response completed") }
        catch { XCTAssertEqual(error as? MCPRequestError, .unexpectedResponse) }
        let second = try await tracker.begin(method: "ping", timeout: .seconds(1), now: now)
        XCTAssertNotEqual(first.id, second.id)
        do { _ = try await tracker.complete(response(second.id), now: now.advanced(by: .seconds(1))); XCTFail("Expired response completed") }
        catch { XCTAssertEqual(error as? MCPRequestError, .timedOut) }
        let third = try await tracker.begin(method: "ping", timeout: .seconds(2), now: now)
        let expired = await tracker.expire(at: now.advanced(by: .seconds(2)))
        XCTAssertEqual(expired, [third])
    }
    func testConnectionIsolationAndCloseRejectLateResponse() async throws {
        let first = try tracker(), second = try tracker()
        let request = try await first.begin(method: "ping", timeout: .seconds(5))
        do { _ = try await second.complete(response(request.id)); XCTFail("Foreign connection accepted") }
        catch { XCTAssertEqual(error as? MCPRequestError, .unexpectedResponse) }
        let abandoned = await first.close(); XCTAssertEqual(abandoned, [request])
        do { _ = try await first.complete(response(request.id)); XCTFail("Closed response accepted") }
        catch { XCTAssertEqual(error as? MCPRequestError, .closed) }
        do { _ = try await first.begin(method: "ping", timeout: .seconds(1)); XCTFail("Closed connection reopened") }
        catch { XCTAssertEqual(error as? MCPRequestError, .closed) }
    }
    func testNotificationsCannotConsumeRequestsAndLimitsAreValidated() async throws {
        XCTAssertThrowsError(try tracker(limit: 0))
        let tracker = try tracker()
        for timeout: Duration in [.zero, .seconds(-1), .seconds(3601)] {
            do { _ = try await tracker.begin(method: "ping", timeout: timeout); XCTFail("Invalid timeout accepted") }
            catch { XCTAssertEqual(error as? MCPRequestError, .invalidRequest) }
        }
        let request = try await tracker.begin(method: "ping", timeout: .seconds(10))
        let notification = try MCPMessage(bytes: Data(#"{"jsonrpc":"2.0","method":"notifications/message"}"#.utf8))
        do { _ = try await tracker.complete(notification); XCTFail("Notification consumed request") }
        catch { XCTAssertEqual(error as? MCPRequestError, .unexpectedResponse) }
        let completed = try await tracker.complete(response(request.id)); XCTAssertEqual(completed, request)
    }
}
