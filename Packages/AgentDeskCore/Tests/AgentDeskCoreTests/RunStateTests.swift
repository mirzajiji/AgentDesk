import Foundation
import XCTest
@testable import AgentDeskCore

final class RunStateTests: XCTestCase {
    func testCompleteTransitionMatrixRejectsTerminalReopeningAndInvalidSkips() {
        let expected: [RunState: Set<RunState>] = [
            .queued: [.running, .waitingForApproval, .failed, .cancelled],
            .running: [.waitingForApproval, .paused, .completed, .failed, .cancelled],
            .waitingForApproval: [.running, .failed, .cancelled],
            .paused: [.running, .failed, .cancelled],
            .completed: [], .failed: [], .cancelled: []
        ]
        for current in RunState.allCases {
            for next in RunState.allCases {
                XCTAssertEqual(current.canTransition(to: next), expected[current]?.contains(next), "\(current) → \(next)")
            }
            XCTAssertEqual(current.isTerminal, [.completed, .failed, .cancelled].contains(current))
        }
    }

    func testRunStateRoundTripAndUnknownValueRejection() throws {
        for state in RunState.allCases { XCTAssertEqual(try JSONDecoder().decode(RunState.self, from: JSONEncoder().encode(state)), state) }
        XCTAssertThrowsError(try JSONDecoder().decode(RunState.self, from: Data("\"unknown\"".utf8)))
    }
}
