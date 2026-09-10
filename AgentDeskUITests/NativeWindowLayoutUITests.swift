#if os(macOS)
import XCTest

final class NativeWindowLayoutUITests: XCTestCase {
    @MainActor
    func testCompactProjectRowsKeepActionsVisibleAndAgentEditorFits() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchEnvironment["AGENTDESK_TEST_RUN_MODE"] = "success"
        app.launch()
        let agents = app.buttons["project.agents.Synthetic run project"]
        XCTAssertTrue(agents.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 908, dy: 718)))
        XCTAssertLessThanOrEqual(window.frame.width, 950)
        for action in ["agents", "setup", "run", "rename"] {
            let button = app.buttons["project.\(action).Synthetic run project"]
            XCTAssertTrue(button.isHittable)
            XCTAssertGreaterThan(button.frame.width, 35)
        }
        let name = app.staticTexts["project.name.Synthetic run project"]
        XCTAssertLessThanOrEqual(name.frame.maxY, agents.frame.minY)
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Compact project row with complete actions"; attachment.lifetime = .keepAlways; add(attachment)
        agents.click()
        let create = app.buttons["agent.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5)); create.click()
        let save = app.buttons["agent.save"]
        XCTAssertTrue(save.waitForExistence(timeout: 5)); XCTAssertTrue(save.isHittable)
        XCTAssertTrue(app.textFields["agent.name"].isHittable)
        app.typeKey(.escape, modifierFlags: [])
    }
}
#endif
