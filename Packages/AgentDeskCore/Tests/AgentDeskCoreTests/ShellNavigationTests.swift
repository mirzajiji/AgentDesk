import XCTest
@testable import AgentDeskCore

final class ShellNavigationTests: XCTestCase {
    func testFreshHostOpensWorkspaceList() {
        XCTAssertEqual(ShellNavigation(role: .macHost).selection, .workspaces)
    }

    func testHostCanNavigateAndRestoreRuns() {
        var navigation = ShellNavigation(role: .macHost)
        XCTAssertTrue(navigation.select(.runs))
        XCTAssertEqual(navigation.selection, .runs)
        XCTAssertEqual(ShellNavigation(role: .macHost, restoring: navigation.selection), navigation)
    }

    func testCompanionDoesNotRestoreHostConfigurationScreen() {
        let navigation = ShellNavigation(role: .iPhoneCompanion, restoring: .connections)
        XCTAssertEqual(navigation.selection, .companion)
    }

    func testInvalidDestinationLeavesSelectionUnchanged() {
        var navigation = ShellNavigation(role: .macHost, restoring: .runs)
        XCTAssertFalse(navigation.select(.companion))
        XCTAssertEqual(navigation.selection, .runs)
    }

    func testUnpairedCompanionHasNoHostNavigation() {
        var navigation = ShellNavigation(role: .iPhoneCompanion)
        for destination in [ShellDestination.workspaces, .runs, .connections] {
            XCTAssertFalse(navigation.select(destination))
            XCTAssertEqual(navigation.selection, .companion)
        }
    }
}
