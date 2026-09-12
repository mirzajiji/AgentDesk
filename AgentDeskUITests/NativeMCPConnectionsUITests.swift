#if os(macOS)
import XCTest

final class NativeMCPConnectionsUITests: XCTestCase {
    @MainActor func testCreateAndReopenConfiguration() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchEnvironment["AGENTDESK_TEST_RUN_MODE"] = "success"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Connections"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["Connections"].firstMatch.click()
        let mcp = app.radioButtons["MCP"]
        XCTAssertTrue(mcp.waitForExistence(timeout: 5)); mcp.click()
        let create = app.buttons["mcp.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5)); create.click()
        for (id, value) in [("mcp.name", "Synthetic MCP"), ("mcp.executable", "/usr/bin/true"), ("mcp.directory", "project")] {
            let field = app.textFields[id]
            XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText(value)
        }
        app.buttons["Add Argument"].click()
        app.textFields["mcp.argument.0"].click()
        app.textFields["mcp.argument.0"].typeText("--version")
        app.buttons["Add Argument"].click()
        app.buttons.matching(identifier: "Remove").element(boundBy: 1).click()
        app.buttons["mcp.save"].click()
        XCTAssertTrue(app.staticTexts["Synthetic MCP"].waitForExistence(timeout: 5))
        let edit = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mcp.edit.")).firstMatch
        edit.click()
        XCTAssertEqual(app.textFields["mcp.executable"].value as? String, "/usr/bin/true")
        XCTAssertEqual(app.textFields["mcp.argument.0"].value as? String, "--version")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Native MCP configuration editor"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Cancel"].click()
    }
}
#endif
