#if os(macOS)
import AgentDeskCore
import AgentDeskRuntime
import XCTest
@testable import AgentDesk

@MainActor final class MutationHistoryModelTests: XCTestCase {
    func testFailedOpenClearsLoadingAndCanBeRetried() async {
        var attempts = 0
        let model = MutationHistoryModel {
            attempts += 1
            throw AuthorizationError.denied
        }
        await model.load()
        XCTAssertFalse(model.loading)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.records.isEmpty)
        XCTAssertFalse(model.hasMore)
        await model.load(more: true)
        XCTAssertEqual(attempts, 1)
        await model.load()
        XCTAssertEqual(attempts, 2)
    }
    func testCloseDiscardsLateOpenFailure() async {
        var pending: CheckedContinuation<Void, Never>?
        let model = MutationHistoryModel {
            await withCheckedContinuation { pending = $0 }
            throw AuthorizationError.denied
        }
        let task = Task { await model.load() }
        while pending == nil { await Task.yield() }
        XCTAssertTrue(model.loading)
        await model.close()
        pending?.resume()
        await task.value
        XCTAssertFalse(model.loading)
        XCTAssertNil(model.errorMessage)
        XCTAssertTrue(model.records.isEmpty)
    }
}
#endif
