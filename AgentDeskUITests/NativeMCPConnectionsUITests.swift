#if os(macOS)
import XCTest

final class NativeMCPConnectionsUITests: XCTestCase {
    @MainActor func testReviewedNativeProcessStartHealthStopAndRestart() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchEnvironment["AGENTDESK_TEST_RUN_MODE"] = "success"
        app.launchEnvironment["AGENTDESK_TEST_MCP_LIFECYCLE"] = "stdio"
        // Both the app and UI runner are sandboxed; never invoke the xcrun shim here.
        let developer = ProcessInfo.processInfo.environment["DEVELOPER_DIR"] ?? "/Applications/Xcode.app/Contents/Developer"
        let python = URL(fileURLWithPath: developer).appendingPathComponent("usr/bin/python3").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: python), "Install Xcode Python or set DEVELOPER_DIR for this fixture")
        app.launchEnvironment["AGENTDESK_TEST_MCP_PYTHON"] = python
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Connections"].firstMatch.waitForExistence(timeout: 15))
        app.staticTexts["Connections"].firstMatch.click()
        XCTAssertTrue(app.radioButtons["MCP"].waitForExistence(timeout: 10)); app.radioButtons["MCP"].click()
        let connection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mcp.connection.")).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10)); connection.click()
        for _ in 0..<2 {
            let review = app.buttons["mcp.lifecycle.review"]
            XCTAssertTrue(review.waitForExistence(timeout: 10)); review.click()
            let approve = app.buttons["mcp.lifecycle.approve"]
            XCTAssertTrue(approve.waitForExistence(timeout: 10))
            XCTAssertFalse(app.buttons["mcp.lifecycle.health"].exists)
            approve.click()
            let health = app.buttons["mcp.lifecycle.health"]
            XCTAssertTrue(health.waitForExistence(timeout: 15)); health.click()
            XCTAssertTrue(app.staticTexts["Server responded to the health check."].waitForExistence(timeout: 10))
            app.buttons["mcp.lifecycle.stop"].click()
            XCTAssertTrue(app.staticTexts["Stopped."].waitForExistence(timeout: 10))
        }
        app.buttons["Done"].click()
    }
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
        app.checkBoxes["Enabled"].click()
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
        app.popUpButtons["mcp.directory-base"].click()
        app.menuItems["Registered repository"].click()
        let directory = app.textFields["mcp.directory"]
        directory.click(); directory.typeKey("a", modifierFlags: .command); directory.typeKey(.delete, modifierFlags: [])
        app.buttons["mcp.save"].click()
        XCTAssertTrue(edit.waitForExistence(timeout: 5)); edit.click()
        XCTAssertEqual(app.textFields["mcp.directory"].value as? String, "")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Native MCP configuration editor"; shot.lifetime = .keepAlways; add(shot)
        app.buttons["Cancel"].click()
        let connection = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mcp.connection.")).firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 5)); connection.click()
        XCTAssertTrue(app.buttons["mcp.lifecycle.review"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["/usr/bin/true"].firstMatch.exists)
        XCTAssertTrue(app.staticTexts["1: --version"].exists)
        XCTAssertFalse(app.buttons["mcp.lifecycle.approve"].exists)
        let lifecycle = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        lifecycle.name = "Native MCP launch review"; lifecycle.lifetime = .keepAlways; add(lifecycle)
        app.buttons["mcp.lifecycle.stop"].click()
        XCTAssertTrue(app.staticTexts["Stopped."].waitForExistence(timeout: 5))
        app.buttons["Done"].click()
    }
}
#endif
