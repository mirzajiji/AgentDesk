#if os(macOS)
import Combine
import XCTest
@testable import AgentDesk
@testable import AgentDeskRuntime

@MainActor
final class NativeReadinessTests: XCTestCase {
    func testSuccessfulCheckPublishesOnlyObservedItems() async {
        let expected = NativeReadinessItem(id: "synthetic", title: "Local test", detail: "Observed", state: .ready)
        let model = NativeReadinessModel { [expected] }
        let done = expectation(description: "Published observation")
        let observer = model.$checkedAt.compactMap { $0 }.prefix(1).sink { _ in done.fulfill() }
        model.refresh()
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(model.items, [expected]); XCTAssertFalse(model.checking); XCTAssertNil(model.error)
        observer.cancel()
        model.cancel(); XCTAssertTrue(model.items.isEmpty); XCTAssertNil(model.checkedAt)
    }
    func testCancelledProbeCannotPublishLateSuccess() async {
        let began = expectation(description: "Probe began"), finished = expectation(description: "Probe returned after cancellation")
        let model = NativeReadinessModel {
            began.fulfill()
            do { try await Task.sleep(for: .seconds(10)) } catch {}
            finished.fulfill()
            return [.init(id: "late", title: "Late", detail: "Must not appear", state: .ready)]
        }
        model.refresh(); await fulfillment(of: [began], timeout: 2)
        model.cancel(); await fulfillment(of: [finished], timeout: 2)
        XCTAssertTrue(model.items.isEmpty); XCTAssertNil(model.checkedAt); XCTAssertFalse(model.checking)
    }
    func testProbeFailureDoesNotExposeRawError() async {
        struct Failure: Error { let secret = "synthetic-error-secret" }
        let model = NativeReadinessModel { throw Failure() }
        let done = expectation(description: "Safe error published")
        let observer = model.$error.compactMap { $0 }.prefix(1).sink { _ in done.fulfill() }
        model.refresh(); await fulfillment(of: [done], timeout: 2)
        XCTAssertFalse(model.error?.contains("synthetic-error-secret") ?? true)
        XCTAssertTrue(model.items.isEmpty); XCTAssertFalse(model.checking); observer.cancel()
    }
    func testGitVersionParserReturnsOnlyNumericVersion() throws {
        let valid = CLICommandOutput(status: 0, stdout: Data("git version 2.50.1 (Apple Git-155)\n".utf8), stderr: Data())
        XCTAssertEqual(try MacGitReadiness.parse(valid), "2.50.1")
        for text in ["password=synthetic-secret", "git version synthetic-secret", "git version 2.50.1-secret", "git version ...", "git version 2..1", "git version 2."] {
            XCTAssertThrowsError(try MacGitReadiness.parse(.init(status: 0, stdout: Data(text.utf8), stderr: Data())))
        }
        XCTAssertThrowsError(try MacGitReadiness.parse(.init(status: 1, stdout: valid.stdout, stderr: Data())))
    }
}
#endif
