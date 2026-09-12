#if os(macOS)
import XCTest
@testable import AgentDesk

@MainActor
final class NativeJiraIssueModelTests: XCTestCase {
    private enum Failure: Error { case synthetic }
    func testInvalidInputDoesNotOpenAndFailureHasNoRawErrorContent() async throws {
        var calls = 0
        let model = NativeJiraIssueModel { key in
            calls += 1; XCTAssertEqual(key, "SYN-1"); throw Failure.synthetic
        }
        model.lookup(); XCTAssertEqual(calls, 0); XCTAssertFalse(model.busy)
        model.identifier = "  SYN-1  "
        model.lookup()
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(calls, 1); XCTAssertFalse(model.busy)
        XCTAssertNil(model.content); XCTAssertNil(model.pending)
        XCTAssertEqual(model.message, "Issue lookup failed. Check the connection, issue key and current permissions.")
    }
    func testCancelledOpeningCannotPublishLateFailure() async throws {
        var continuation: CheckedContinuation<Void, Never>?
        let model = NativeJiraIssueModel { _ in
            await withCheckedContinuation { continuation = $0 }
            throw Failure.synthetic
        }
        model.identifier = "SYN-1"; model.lookup()
        for _ in 0..<100 where continuation == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(continuation); XCTAssertTrue(model.busy)
        model.cancel(); continuation?.resume()
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.busy); XCTAssertNil(model.message)
        XCTAssertNil(model.content); XCTAssertNil(model.pending)
    }
}
#endif
