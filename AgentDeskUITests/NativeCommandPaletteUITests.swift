#if os(macOS)
import XCTest

final class NativeCommandPaletteUITests: XCTestCase {
    @MainActor
    func testKeyboardSearchOpensRunForReviewWithoutStartingExecution() {
        continueAfterFailure = false
        let app = fixture(); app.launch()
        XCTAssertTrue(app.buttons["project.run.Synthetic run project"].waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["command.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("run agent synthetic")
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.buttons["run.console.done"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["run.start"].exists)
        XCTAssertFalse(app.buttons["run.cancel"].exists)
        app.buttons["run.console.done"].click()
        app.typeKey("k", modifierFlags: .command)
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("create project synthetic")
        app.buttons["command.open"].click()
        XCTAssertTrue(app.textFields["catalog.name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Workspace: Synthetic run workspace"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testNoMatchesAndEscapeInCompactWindow() {
        continueAfterFailure = false
        let app = fixture(); app.launch()
        XCTAssertTrue(app.buttons["project.run.Synthetic run project"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 908, dy: 718)))
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["command.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("nonexistent capability")
        XCTAssertFalse(app.buttons["command.open"].isEnabled)
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        XCTAssertLessThanOrEqual(app.sheets.firstMatch.frame.height, window.frame.height - 40)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Compact native command palette"; attachment.lifetime = .keepAlways; add(attachment)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(search.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["project.run.Synthetic run project"].isHittable)
    }

    @MainActor
    func testArrowSelectionOpensSecondMatchingCommand() {
        continueAfterFailure = false
        let app = fixture(); app.launch()
        XCTAssertTrue(app.buttons["project.run.Synthetic run project"].waitForExistence(timeout: 10))
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["command.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.typeText("synthetic")
        app.typeKey(.downArrow, modifierFlags: [])
        app.typeKey(.return, modifierFlags: [])
        XCTAssertTrue(app.textFields["catalog.name"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Workspace: Synthetic run workspace"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor private func fixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchEnvironment["AGENTDESK_TEST_RUN_MODE"] = "success"
        return app
    }
}
#endif
