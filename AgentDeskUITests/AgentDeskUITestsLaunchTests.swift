import XCTest

final class AgentDeskUITestsLaunchTests: XCTestCase {

    override class var runsForEachTargetApplicationUIConfiguration: Bool {
        true
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunch() throws {
        let app = XCUIApplication()
        app.launch()

        #if os(macOS)
        XCTAssertTrue(app.staticTexts["No workspaces yet"].waitForExistence(timeout: 5))
        #else
        XCTAssertTrue(app.staticTexts["No Mac connected"].waitForExistence(timeout: 5))
        #endif

        #if os(macOS)
        // Capture only AgentDesk; a desktop screenshot can include other workspaces.
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        #else
        let attachment = XCTAttachment(screenshot: app.screenshot())
        #endif
        attachment.name = "AgentDesk initial state"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
