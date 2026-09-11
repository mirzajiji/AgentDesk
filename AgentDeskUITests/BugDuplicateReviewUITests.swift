#if os(macOS)
import Foundation
import XCTest

final class BugDuplicateReviewUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    @MainActor func testSelectedBugHeaderStaysAtTop() {
        let app = fixture("duplicate"); app.launch()
        click("project.bugs.Synthetic run project", app)
        let row = app.staticTexts["Incoming synthetic finding"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        let title = app.staticTexts["bug.detail.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        attach(app, "Selected bug spacing")
        let status = app.popUpButtons["bugs.filter.status"]
        let archived = app.checkBoxes["bugs.filter.archived"]
        XCTAssertLessThan(archived.frame.maxY - status.frame.minY, 80,
                          "Filters should share rows instead of pushing the bug list down")
        let sheet = app.sheets.firstMatch
        XCTAssertLessThan(app.staticTexts["bugs.title"].frame.minY - sheet.frame.minY, 40)
        XCTAssertLessThan(title.frame.minY - app.scrollViews["bug.detail.scroll"].frame.minY, 36)
    }
    @MainActor func testKnownTicketDraftAndReviewedDecisionPersist() {
        let app = fixture("duplicate"); app.launch(); openReview(app)
        click("Prepare Ticket Addition", app, scroll: "bug.review.scroll")
        let copy = app.buttons["bug.draft.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 10), app.staticTexts["bug.review.error"].firstMatch.value as? String ?? "No draft error shown"); reveal(copy, app, "bug.review.scroll")
        XCTAssertTrue(copy.isHittable)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "synthetic-review-secret")).firstMatch.exists)
        attach(app, "Native known-ticket draft")
        let picker = app.popUpButtons["bug.decision.resolution"]
        reveal(picker, app, "bug.review.scroll"); picker.click(); app.menuItems["Duplicate"].click()
        let reason = app.textFields["bug.decision.reason"]
        reveal(reason, app, "bug.review.scroll"); reason.click(); reason.typeText("Reviewed identical synthetic behavior")
        click("bug.decision.review", app, scroll: "bug.review.scroll")
        XCTAssertTrue(app.buttons["bug.decision.publish"].waitForExistence(timeout: 5), app.staticTexts["bug.review.error"].firstMatch.value as? String ?? "No decision error shown")
        XCTAssertTrue(app.buttons["bug.decision.publish"].isHittable)
        attach(app, "Native exact comparison decision")
        click("bug.decision.publish", app)
        XCTAssertTrue(app.staticTexts["Recorded user decision: Duplicate"].waitForExistence(timeout: 5), app.staticTexts["bug.review.error"].firstMatch.value as? String ?? "No publication error shown")
        click("bug.review.done", app); app.terminate(); app.launch()
        click("project.bugs.Synthetic run project", app)
        let row = app.staticTexts["Incoming synthetic finding"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.click()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Viewing v2 · open · observed"), object: app.staticTexts["bug.detail.version"])], timeout: 5), .completed)
    }
    @MainActor func testNewReportRequiresExplicitDuplicateDecision() {
        let app = fixture("duplicate"); app.launch(); openReview(app)
        func prepareReport() {
            let disclosure = app.buttons["bug.report.form"]
            XCTAssertTrue(disclosure.waitForExistence(timeout: 5))
            reveal(disclosure, app, "bug.review.scroll")
            disclosure.click()
            let component = app.popUpButtons["bug.report.component"]
            XCTAssertTrue(component.waitForExistence(timeout: 5)); reveal(component, app, "bug.review.scroll")
            component.click(); app.menuItems["Backend"].click()
            let region = app.popUpButtons["bug.report.region"]
            reveal(region, app, "bug.review.scroll"); region.click(); app.menuItems["GEO"].click()
            for (id, value) in [("bug.report.area", "Payments"), ("bug.report.module", "Refunds")] {
                let field = app.textFields[id]; reveal(field, app, "bug.review.scroll"); field.click(); field.typeText(value)
            }
            click("bug.report.prepare", app, scroll: "bug.review.scroll")
        }
        prepareReport()
        XCTAssertTrue(app.staticTexts["bug.review.error"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["bug.draft.copy"].exists)
        let reason = app.textFields["bug.decision.reason"]
        reveal(reason, app, "bug.review.scroll"); reason.click(); reason.typeText("Explicit synthetic distinction for report review")
        click("bug.decision.review", app, scroll: "bug.review.scroll")
        click("bug.decision.publish", app)
        XCTAssertTrue(app.staticTexts["Recorded user decision: Distinct"].waitForExistence(timeout: 5))
        prepareReport()
        let copy = app.buttons["bug.draft.copy"]
        XCTAssertTrue(copy.waitForExistence(timeout: 5)); reveal(copy, app, "bug.review.scroll")
        XCTAssertTrue(copy.isHittable)
        attach(app, "Native CityPay draft after explicit duplicate review")
    }
    @MainActor func testAmbiguityTransfersToApprovedRunWithoutSavingDecision() {
        let app = fixture("ambiguous"); app.launch(); openReview(app)
        click("bug.ambiguity.open", app)
        click("run.context.review", app, scroll: "run.console.scroll")
        click("run.bug.prepare", app, scroll: "run.console.scroll")
        click("run.start", app, scroll: "run.console.scroll")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "completed"), object: app.staticTexts["run.state"])], timeout: 15), .completed)
        attach(app, "Native approved ambiguity result")
        click("run.console.done", app); click("bug.review.done", app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Viewing v1 · open · observed"), object: app.staticTexts["bug.detail.version"])], timeout: 5), .completed)
    }
    @MainActor private func fixture(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchEnvironment["AGENTDESK_TEST_RUN_MODE"] = "success"
        app.launchEnvironment["AGENTDESK_TEST_BUG_REVIEW_MODE"] = mode
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        return app
    }
    @MainActor private func openReview(_ app: XCUIApplication) {
        click("project.bugs.Synthetic run project", app)
        let row = app.staticTexts["Incoming synthetic finding"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10)); row.click()
        click("bug.duplicates", app, scroll: "bug.detail.scroll")
        let agent = app.popUpButtons["bug.review.agent"]
        XCTAssertTrue(agent.waitForExistence(timeout: 5)); agent.click(); app.menuItems["Synthetic reviewer"].click()
        app.popUpButtons["bug.review.environment"].click(); app.menuItems["Development"].click()
        click("bug.review.context", app); click("bug.review.compare", app)
        XCTAssertTrue(app.buttons["Refresh Comparison"].waitForExistence(timeout: 10))
    }
    @MainActor private func click(_ id: String, _ app: XCUIApplication, scroll: String? = nil) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 10))
        if let scroll { reveal(button, app, scroll) }
        button.click()
    }
    @MainActor private func reveal(_ element: XCUIElement, _ app: XCUIApplication, _ id: String) {
        let scroll = app.scrollViews[id]
        for _ in 0..<25 {
            if element.isHittable && element.frame.minY >= scroll.frame.minY && element.frame.maxY <= scroll.frame.maxY { return }
            scroll.scroll(byDeltaX: 0, deltaY: element.frame.minY < scroll.frame.minY ? -150 : 150)
        }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func attach(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
#endif
