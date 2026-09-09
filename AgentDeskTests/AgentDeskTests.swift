import AgentDeskCore
import XCTest

final class AgentDeskTests: XCTestCase {
    func testPlatformRestoresOnlyItsOwnNavigation() {
        #if os(macOS)
        let navigation = ShellNavigation(role: .macHost, restoring: .companion)
        XCTAssertEqual(navigation.selection, .workspaces)
        #else
        let navigation = ShellNavigation(role: .iPhoneCompanion, restoring: .connections)
        XCTAssertEqual(navigation.selection, .companion)
        #endif
    }
}
