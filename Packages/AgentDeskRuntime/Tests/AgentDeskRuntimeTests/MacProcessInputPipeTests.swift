#if os(macOS)
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class MacProcessInputPipeTests: XCTestCase {
    func testInteractiveRepliesCanEnqueueMoreStdinWithoutClosingEarly() async throws {
        let pipe = MacProcessInputPipe(), state = Mutex((received: Data(), sent: false))
        try pipe.write(Data("first\n".utf8))
        let exit = try await MacProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "IFS= read -r first; printf 'reply:%s\\n' \"$first\"; IFS= read -r second; printf 'reply:%s\\n' \"$second\"; /bin/cat"],
            directory: URL(fileURLWithPath: "/private/tmp"), environment: [:], interactiveInput: pipe,
            timeout: .seconds(3), maximumBytes: 1_024) { chunk in
            try state.withLock {
                $0.received.append(chunk.bytes)
                if !$0.sent && String(decoding: $0.received, as: UTF8.self).contains("reply:first\n") {
                    $0.sent = true; try pipe.write(Data("second\n".utf8)); pipe.close()
                }
            }
        }
        XCTAssertEqual(exit.code, 0)
        XCTAssertEqual(state.withLock { String(decoding: $0.received, as: UTF8.self) }, "reply:first\nreply:second\n")
        XCTAssertThrowsError(try pipe.write(Data("late".utf8)))
    }
    func testCancellationWhileWaitingForInputClosesMailboxAndChild() async throws {
        let pipe = MacProcessInputPipe()
        let work = Task {
            try await MacProcessRunner.run(executable: URL(fileURLWithPath: "/bin/cat"), arguments: [],
                directory: URL(fileURLWithPath: "/private/tmp"), environment: [:], interactiveInput: pipe,
                timeout: .seconds(5), maximumBytes: 100) { _ in }
        }
        try await Task.sleep(for: .milliseconds(60)); work.cancel()
        do { _ = try await work.value; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertThrowsError(try pipe.write(Data("late".utf8)))
    }
    func testQueueBoundsCloseAndCancellationAreExplicit() throws {
        let pipe = MacProcessInputPipe()
        for _ in 0..<128 { try pipe.write(Data([1])) }
        XCTAssertThrowsError(try pipe.write(Data([2])))
        pipe.cancel()
        if case .end = pipe.read() {} else { XCTFail("Cancelled pipe retained bytes") }
        let finite = MacProcessInputPipe(); try finite.write(Data("accepted".utf8)); finite.close()
        XCTAssertThrowsError(try finite.write(Data([3])))
        if case .bytes(let bytes) = finite.read() { XCTAssertEqual(bytes, Data("accepted".utf8)) } else { XCTFail("Close discarded accepted bytes") }
        if case .end = finite.read() {} else { XCTFail("Close did not send EOF") }
        let oversized = MacProcessInputPipe()
        XCTAssertThrowsError(try oversized.write(Data(repeating: 1, count: 1_048_577)))
    }
}
#endif
