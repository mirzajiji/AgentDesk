#if os(macOS)
import XCTest

final class NativeConnectionsUITests: XCTestCase {
    @MainActor func testIssueApprovalAndCancellationDisplayOnlyReviewedResult() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchEnvironment["AGENTDESK_TEST_RUN_MODE"] = "success"
        app.launchEnvironment["AGENTDESK_TEST_JIRA_LAYOUT"] = "reference-only"
        app.launchEnvironment["AGENTDESK_TEST_JIRA_ISSUE"] = "approval"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Connections"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["Connections"].firstMatch.click()
        let issue = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "connection.issue.")).firstMatch
        XCTAssertTrue(issue.waitForExistence(timeout: 10)); issue.click()
        let key = app.textFields["jira.issue.key"]
        XCTAssertTrue(key.waitForExistence(timeout: 5)); key.click(); key.typeText("SYN-1")
        app.buttons["jira.issue.lookup"].click()
        let approve = app.buttons["jira.issue.approve"]
        XCTAssertTrue(approve.waitForExistence(timeout: 5)); XCTAssertFalse(key.isEnabled)
        XCTAssertFalse((app.staticTexts["jira.issue.content"].value as? String ?? "").contains("Synthetic issue"))
        app.buttons["jira.issue.cancel"].click()
        XCTAssertFalse(approve.exists); XCTAssertTrue(key.isEnabled)
        app.buttons["jira.issue.lookup"].click()
        XCTAssertTrue(approve.waitForExistence(timeout: 5)); approve.click()
        let content = app.staticTexts["jira.issue.content"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "Synthetic issue"), object: content)], timeout: 5), .completed)
        XCTAssertFalse((content.value as? String ?? "").contains("private-test-value"))
        XCTAssertFalse(approve.exists); XCTAssertTrue(key.isEnabled)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Approved synthetic Jira issue result"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testCredentialActionsFitCompactWindow() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchEnvironment["AGENTDESK_TEST_RUN_MODE"] = "success"
        app.launchEnvironment["AGENTDESK_TEST_JIRA_LAYOUT"] = "reference-only"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Connections"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["Connections"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["synthetic.atlassian.net"].waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 908, dy: 718)))
        XCTAssertLessThanOrEqual(window.frame.width, 950)
        for prefix in ["login", "refresh-grant", "test", "logout", "issue", "permissions", "reset", "edit"] {
            let action = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "connection." + prefix + ".")).firstMatch
            XCTAssertTrue(action.exists)
            XCTAssertGreaterThan(action.frame.width, 35)
            XCTAssertGreaterThanOrEqual(action.frame.minX, window.frame.minX)
            XCTAssertLessThanOrEqual(action.frame.maxX, window.frame.maxX)
            XCTAssertLessThanOrEqual(action.frame.maxY, window.frame.maxY)
        }
        let attachment = XCTAttachment(screenshot: window.screenshot())
        attachment.name = "Compact Jira lifecycle actions"; attachment.lifetime = .keepAlways; add(attachment)
        let issue = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "connection.issue.")).firstMatch
        issue.click()
        XCTAssertTrue(app.textFields["jira.issue.key"].waitForExistence(timeout: 5))
        app.buttons["jira.issue.lookup"].click()
        XCTAssertEqual(app.staticTexts["jira.issue.message"].value as? String, "Enter a Jira issue key.")
        XCTAssertFalse(app.buttons["jira.issue.approve"].exists)
        let issueShot = XCTAttachment(screenshot: window.screenshot())
        issueShot.name = "Native Jira issue lookup"; issueShot.lifetime = .keepAlways; add(issueShot)
        app.sheets.firstMatch.buttons["Done"].click()
        let reset = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "connection.reset.")).firstMatch
        reset.click()
        XCTAssertTrue(app.sheets.firstMatch.buttons["Reset Connection"].waitForExistence(timeout: 5))
        app.sheets.firstMatch.buttons["Cancel"].click()
        XCTAssertTrue(app.staticTexts["Configuration version 1"].exists)
        reset.click(); app.sheets.firstMatch.buttons["Reset Connection"].click()
        XCTAssertTrue(app.staticTexts["Configuration version 2"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Disabled"].exists)
        XCTAssertFalse(app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "connection.logout.")).firstMatch.exists)
    }

    @MainActor func testPermissionReviewPersistsAfterRelaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchEnvironment["AGENTDESK_TEST_RUN_MODE"] = "success"
        app.launchEnvironment["AGENTDESK_TEST_JIRA_LAYOUT"] = "reference-only"
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Connections"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["Connections"].firstMatch.click()
        let permissions = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "connection.permissions.")).firstMatch
        XCTAssertTrue(permissions.waitForExistence(timeout: 10)); permissions.click()
        let picker = app.popUpButtons["permissions.rule.issuesRead"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["permissions.save"].exists)
        picker.click(); app.menuItems["Require approval"].click()
        app.buttons["permissions.review"].click()
        XCTAssertTrue(app.staticTexts["permissions.change.issuesRead"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts["permissions.change.issuesRead"].value as? String, "Read issues: deny → approval")
        app.buttons["permissions.save"].click()
        XCTAssertTrue(app.staticTexts["Configuration version 2"].waitForExistence(timeout: 10))
        app.terminate(); app.launch()
        XCTAssertTrue(app.staticTexts["Connections"].firstMatch.waitForExistence(timeout: 10))
        app.staticTexts["Connections"].firstMatch.click()
        XCTAssertTrue(permissions.waitForExistence(timeout: 10)); permissions.click()
        XCTAssertTrue(picker.waitForExistence(timeout: 5))
        XCTAssertEqual(picker.value as? String, "Require approval")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Persisted Jira permission editor"; shot.lifetime = .keepAlways; add(shot)
    }

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
