import XCTest
#if os(iOS)
import UIKit
#endif

final class AgentDeskUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsTruthfulEmptyState() {
        let app = XCUIApplication()
        app.launch()
        #if os(macOS)
        XCTAssertTrue(app.staticTexts["No workspaces yet"].waitForExistence(timeout: 5))
        #else
        XCTAssertTrue(app.staticTexts["No Mac connected"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Run"].exists)
        #endif
        XCTAssertFalse(app.staticTexts["Hello, world!"].exists)
    }

    #if os(macOS)
    @MainActor
    func testSidebarNavigatesBetweenEmptySections() {
        let app = XCUIApplication()
        app.launch()
        app.staticTexts["Runs"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No runs yet"].waitForExistence(timeout: 5))
        app.staticTexts["Connections"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No connections configured"].waitForExistence(timeout: 5))
        app.staticTexts["Workspaces"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No workspaces yet"].waitForExistence(timeout: 5))
    }
    #else
    @MainActor
    func testCompanionSupportsLargestAccessibilityText() {
        let app = XCUIApplication()
        app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        app.launch()
        XCTAssertTrue(app.staticTexts["No Mac connected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Mac connected"].isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Companion largest accessibility text"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCompanionRemainsDisconnectedAfterRotation() {
        let app = XCUIApplication()
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.staticTexts["No Mac connected"].waitForExistence(timeout: 5))
    }
    #endif
}
