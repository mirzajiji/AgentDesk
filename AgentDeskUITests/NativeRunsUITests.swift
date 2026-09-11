#if os(macOS)
import XCTest

final class NativeRunsUITests: XCTestCase {
    @MainActor
    func testMutationHistoryShowsConfirmedAndUnresolvedAttempts() {
        continueAfterFailure = false
        let app = fixture()
        app.launchEnvironment["AGENTDESK_TEST_MUTATION_HISTORY"] = "seeded"
        app.launch()
        let run = app.buttons["project.run.Synthetic run project"]
        XCTAssertTrue(run.waitForExistence(timeout: 10)); run.click()
        XCTAssertTrue(app.popUpButtons["run.agent"].waitForExistence(timeout: 5))
        app.popUpButtons["run.agent"].click(); app.menuItems["Synthetic reviewer"].click()
        app.buttons["mutation.history.open"].click()
        XCTAssertTrue(app.staticTexts["Acknowledged by Jira"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Unresolved — verify Jira state"].exists)
        XCTAssertFalse(app.staticTexts["mutation.history.error"].exists)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Mutation history outcomes"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["mutation.history.done"].click()
    }

    @MainActor
    func testMutationHistoryOpensWithCompactHeaderAndCloses() {
        continueAfterFailure = false
        let app = fixture(); app.launch()
        let run = app.buttons["project.run.Synthetic run project"]
        XCTAssertTrue(run.waitForExistence(timeout: 10)); run.click()
        XCTAssertTrue(app.popUpButtons["run.agent"].waitForExistence(timeout: 5))
        app.popUpButtons["run.agent"].click(); app.menuItems["Synthetic reviewer"].click()
        let history = app.buttons["mutation.history.open"]
        XCTAssertTrue(history.waitForExistence(timeout: 5)); history.click()
        let title = app.staticTexts["mutation.history.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["No mutation attempts"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["mutation.history.error"].exists)
        let done = app.buttons["mutation.history.done"]
        XCTAssertTrue(done.isHittable)
        XCTAssertLessThan(abs(title.frame.minY - done.frame.minY), 45)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Mutation history empty state"; attachment.lifetime = .keepAlways; add(attachment)
        done.click()
        XCTAssertTrue(title.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["run.console.done"].isHittable)
    }

    @MainActor
    func testRunsPageOpensScopedConsoleAndEmptyHistory() {
        continueAfterFailure = false
        let app = fixture(); app.launch()
        XCTAssertTrue(app.buttons["project.run.Synthetic run project"].waitForExistence(timeout: 10))
        app.staticTexts["Runs"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["runs.sessions.empty"].waitForExistence(timeout: 5))
        let project = app.buttons["runs.project.Synthetic run workspace / Synthetic run project"]
        XCTAssertTrue(project.waitForExistence(timeout: 5)); project.click()
        XCTAssertTrue(app.buttons["run.console.done"].waitForExistence(timeout: 5))
        app.popUpButtons["run.agent"].click()
        app.menuItems["Synthetic reviewer"].click()
        app.buttons["run.history.open"].click()
        XCTAssertTrue(app.staticTexts["run.history.empty"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["run.start"].exists)
        app.buttons["run.console.done"].click()
    }

    @MainActor
    func testMenuBarReportsNoOpenSessions() {
        continueAfterFailure = false
        let app = fixture(); app.launch()
        XCTAssertTrue(app.buttons["project.run.Synthetic run project"].waitForExistence(timeout: 10))
        let bars = app.menuBars
        XCTAssertGreaterThan(bars.count, 1)
        app.descendants(matching: .statusItem).firstMatch.click()
        XCTAssertTrue(app.menuItems["Running: 0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Awaiting approval: 0"].exists)
        XCTAssertTrue(app.menuItems["Failed: 0"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor
    func testMenuReflectsApprovalRunningAndCloseAndFocusesExistingConsole() {
        continueAfterFailure = false
        let app = fixture()
        app.launchEnvironment["AGENTDESK_TEST_RUN_MODE"] = "quiet"
        app.launch()
        let open = app.buttons["project.run.Synthetic run project"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.click()
        app.popUpButtons["run.agent"].click(); app.menuItems["Synthetic reviewer"].click()
        app.buttons["run.context.review"].click()
        let editor = app.textViews["run.task"]; reveal(editor, app: app); editor.click(); editor.typeText("Inspect synthetic files")
        let prepare = app.buttons["run.prepare"]; reveal(prepare, app: app); prepare.click()
        XCTAssertTrue(app.buttons["run.start"].waitForExistence(timeout: 10))
        let windowCount = app.windows.count
        app.descendants(matching: .statusItem).firstMatch.click()
        clickVisibleMenuItem(app.menuItems["Open AgentDesk"])
        let openedWindow = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in app.windows.count > windowCount }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [openedWindow], timeout: 5), .completed)
        let browser = app.windows.allElementsBoundByIndex.first { $0.sheets.count == 0 && $0.buttons["project.run.Synthetic run project"].exists }
        XCTAssertNotNil(browser)
        browser?.staticTexts["Runs"].firstMatch.click()
        let sessionRow = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "runs.session.")).firstMatch
        XCTAssertTrue(sessionRow.waitForExistence(timeout: 5)); sessionRow.click()
        XCTAssertEqual(app.sheets.count, 1)
        app.descendants(matching: .statusItem).firstMatch.click()
        XCTAssertTrue(app.menuItems["Awaiting approval: 1"].waitForExistence(timeout: 5))
        let item = app.menuItems["Synthetic run project — waitingForApproval"]
        XCTAssertTrue(item.exists); clickVisibleMenuItem(item)
        XCTAssertEqual(app.sheets.count, 1)
        let start = app.buttons["run.start"]; reveal(start, app: app); start.click()
        XCTAssertTrue(app.buttons["run.cancel"].waitForExistence(timeout: 10))
        app.descendants(matching: .statusItem).firstMatch.click()
        XCTAssertTrue(app.menuItems["Running: 1"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Awaiting approval: 0"].exists)
        app.typeKey(.escape, modifierFlags: [])
        app.buttons["run.console.done"].click()
        app.windows.firstMatch.buttons["Stop and Close"].click()
        XCTAssertTrue(app.buttons["run.console.done"].waitForNonExistence(timeout: 10))
        app.descendants(matching: .statusItem).firstMatch.click()
        XCTAssertTrue(app.menuItems["Running: 0"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["No open run sessions"].exists)
        app.typeKey(.escape, modifierFlags: [])
    }

    @MainActor private func clickVisibleMenuItem(_ item: XCUIElement) {
        let visible = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            item.exists && item.isHittable && item.frame.width > 0 && item.frame.height > 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [visible], timeout: 5), .completed)
        item.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    @MainActor private func reveal(_ element: XCUIElement, app: XCUIApplication) {
        let scroll = app.scrollViews["run.console.scroll"]
        for _ in 0..<16 {
            if element.exists, element.isHittable, element.frame.minY >= scroll.frame.minY, element.frame.maxY <= scroll.frame.maxY { return }
            scroll.scroll(byDeltaX: 0, deltaY: element.exists && element.frame.minY < scroll.frame.minY ? -150 : 150)
        }
        XCTFail("Console control remained outside its viewport")
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
