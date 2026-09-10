#if os(macOS)
import XCTest

final class NativeReadinessUITests: XCTestCase {
    @MainActor
    func testReadinessCanCloseAndRouteToWorkspaceCreationWithoutSaving() {
        continueAfterFailure = false
        let app = fixture(); app.launch()
        let open = app.buttons["readiness.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.click()
        XCTAssertTrue(app.buttons["readiness.done"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.buttons["readiness.done"].waitForNonExistence(timeout: 5))
        open.click()
        let create = app.buttons["readiness.workspace"]
        XCTAssertTrue(create.waitForExistence(timeout: 5)); create.click()
        XCTAssertTrue(app.textFields["catalog.name"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["catalog.name"].value as? String, "")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(app.staticTexts["No workspaces yet"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testReadinessRoutesToCodexSettings() {
        continueAfterFailure = false
        let app = fixture(); app.launch()
        let open = app.buttons["readiness.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.click()
        let settings = app.buttons["readiness.settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5)); settings.click()
        XCTAssertTrue(app.buttons["codex.refresh"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["codex.choose"].isHittable)
        XCTAssertFalse(app.buttons["readiness.done"].exists)
    }

    @MainActor private func fixture() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        return app
    }
}
#endif
