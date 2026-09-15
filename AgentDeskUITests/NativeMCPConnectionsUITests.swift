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
            app.buttons["mcp.lifecycle.discover"].click()
            XCTAssertTrue(app.buttons["Approve Tool Discovery"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["mcp.tool.0"].exists)
            app.buttons["Approve Tool Discovery"].click()
            XCTAssertTrue(app.staticTexts["mcp.tool.0"].waitForExistence(timeout: 10))
            let tool = app.staticTexts["mcp.tool.0"]
            XCTAssertEqual(tool.value as? String ?? tool.label, "Synthetic health tool")
            let details = app.scrollViews["mcp.lifecycle.details"]
            for _ in 0..<12 where !details.frame.contains(tool.frame) {
                details.scroll(byDeltaX: 0, deltaY: tool.frame.minY < details.frame.minY ? -150 : 150)
            }
            XCTAssertTrue(details.frame.contains(tool.frame), "Discovered tool must be visible in the scroll area")
            let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            shot.name = "Native MCP discovered tools"; shot.lifetime = .keepAlways; add(shot)
            app.buttons["mcp.lifecycle.prompts"].click()
            XCTAssertTrue(app.buttons["Approve Prompt Discovery"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["mcp.prompt.0"].exists)
            app.buttons["Approve Prompt Discovery"].click()
            let prompt = app.staticTexts["mcp.prompt.0"]
            XCTAssertTrue(prompt.waitForExistence(timeout: 10))
            XCTAssertEqual(prompt.value as? String ?? prompt.label, "Synthetic review prompt")
            let argument = app.staticTexts["The synthetic change to review."]
            XCTAssertTrue(argument.exists)
            for _ in 0..<16 where !details.frame.contains(argument.frame) {
                details.scroll(byDeltaX: 0, deltaY: argument.frame.minY < details.frame.minY ? -150 : 150)
            }
            XCTAssertTrue(details.frame.contains(argument.frame))
            let promptShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            promptShot.name = "Native MCP prompt descriptions"; promptShot.lifetime = .keepAlways; add(promptShot)
            app.buttons["mcp.lifecycle.resources"].click()
            XCTAssertTrue(app.buttons["Approve Resource Discovery"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["mcp.resource.0"].exists)
            app.buttons["Approve Resource Discovery"].click()
            let resource = app.staticTexts["mcp.resource.0"]
            XCTAssertTrue(resource.waitForExistence(timeout: 10))
            XCTAssertEqual(resource.value as? String ?? resource.label, "Synthetic evidence resource")
            let size = app.staticTexts["Size: 42 bytes"]
            XCTAssertTrue(size.exists)
            for _ in 0..<16 where !details.frame.contains(size.frame) {
                details.scroll(byDeltaX: 0, deltaY: size.frame.minY < details.frame.minY ? -150 : 150)
            }
            XCTAssertTrue(details.frame.contains(size.frame))
            let resourceShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            resourceShot.name = "Native MCP resource descriptions"; resourceShot.lifetime = .keepAlways; add(resourceShot)
            let read = app.buttons["mcp.resource.read.0"]
            for _ in 0..<16 where !details.frame.contains(read.frame) {
                details.scroll(byDeltaX: 0, deltaY: read.frame.minY < details.frame.minY ? -150 : 150)
            }
            read.click()
            XCTAssertTrue(app.buttons["Approve Resource Read"].waitForExistence(timeout: 10))
            XCTAssertFalse(app.staticTexts["mcp.resource.content.0"].exists)
            app.buttons["Approve Resource Read"].click()
            let body = app.staticTexts["mcp.resource.content.0"]
            XCTAssertTrue(body.waitForExistence(timeout: 10))
            XCTAssertEqual(body.value as? String ?? body.label, "Synthetic evidence body.")
            for _ in 0..<16 where !details.frame.contains(body.frame) {
                details.scroll(byDeltaX: 0, deltaY: body.frame.minY < details.frame.minY ? -150 : 150)
            }
            XCTAssertTrue(details.frame.contains(body.frame))
            XCTAssertTrue(app.staticTexts["Binary content: 3 bytes. Preview unavailable."].exists)
            let contentShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            contentShot.name = "Native MCP resource content"; contentShot.lifetime = .keepAlways; add(contentShot)
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
        let credentials = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "mcp.credentials.")).firstMatch
        XCTAssertTrue(credentials.waitForExistence(timeout: 5)); credentials.click()
        XCTAssertTrue(app.secureTextFields["mcp.credential.value"].waitForExistence(timeout: 5))
        app.textFields["mcp.credential.variable"].click(); app.textFields["mcp.credential.variable"].typeText("TOKEN")
        app.secureTextFields["mcp.credential.value"].click(); app.secureTextFields["mcp.credential.value"].typeText("synthetic-cancelled-value")
        let credentialShot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        credentialShot.name = "Native secure MCP credential entry"; credentialShot.lifetime = .keepAlways; add(credentialShot)
        app.buttons["Cancel"].click()
        XCTAssertTrue(credentials.waitForExistence(timeout: 5)); credentials.click()
        XCTAssertEqual(app.secureTextFields["mcp.credential.value"].value as? String ?? "", "")
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
