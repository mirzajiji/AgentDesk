#if os(macOS)
import XCTest

final class NativeConnectionsUITests: XCTestCase {
    @MainActor func testJiraConfigurationPersistsAndCanBeDisabled() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchEnvironment["AGENTDESK_TEST_RUN_MODE"] = "success"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["project.run.Synthetic run project"].waitForExistence(timeout: 10))
        app.staticTexts["Connections"].firstMatch.click()
        let create = app.buttons["connections.create"]
        XCTAssertTrue(create.waitForExistence(timeout: 5)); XCTAssertTrue(create.isEnabled); create.click()
        let field = app.textFields["connection.instance"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText("http://synthetic.atlassian.net")
        app.buttons["connection.save"].click()
        XCTAssertTrue(app.staticTexts["connection.editor.error"].waitForExistence(timeout: 5))
        field.click(); app.typeKey("a", modifierFlags: .command); field.typeText("https://synthetic.atlassian.net")
        app.descendants(matching: .any).matching(identifier: "connection.enabled").firstMatch.click()
        app.buttons["connection.save"].click()
        XCTAssertTrue(app.staticTexts["Enabled · Authentication not checked"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["connections.registration.unavailable"].exists)
        let signIn = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "connection.login.")).firstMatch
        XCTAssertTrue(signIn.exists); XCTAssertFalse(signIn.isEnabled)
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Connections"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["Connections"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["synthetic.atlassian.net"].waitForExistence(timeout: 10))
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "connection.edit.")).firstMatch.click()
        XCTAssertTrue(app.textFields["connection.instance"].waitForExistence(timeout: 5))
        app.descendants(matching: .any).matching(identifier: "connection.enabled").firstMatch.click(); app.buttons["connection.save"].click()
        XCTAssertTrue(app.staticTexts["Disabled"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Configuration version 2"].exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Native saved Jira configuration"; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
