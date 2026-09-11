import XCTest
@testable import JiraOAuthBroker

final class BrokerRequestBudgetTests: XCTestCase {
    func testBurstFractionalRefillAndCapacityBound() {
        let start = ContinuousClock.now
        var budget = BrokerRequestBudget(capacity: 2, refillPerSecond: 2, now: start)
        XCTAssertTrue(budget.admit(now: start))
        XCTAssertTrue(budget.admit(now: start))
        XCTAssertFalse(budget.admit(now: start))
        XCTAssertFalse(budget.admit(now: start.advanced(by: .milliseconds(250))))
        XCTAssertTrue(budget.admit(now: start.advanced(by: .milliseconds(500))))
        XCTAssertFalse(budget.admit(now: start.advanced(by: .milliseconds(500))))
        let later = start.advanced(by: .seconds(1000))
        XCTAssertTrue(budget.admit(now: later))
        XCTAssertTrue(budget.admit(now: later))
        XCTAssertFalse(budget.admit(now: later))
        XCTAssertFalse(budget.admit(now: start), "Backward time must not mint credits")
    }
}
