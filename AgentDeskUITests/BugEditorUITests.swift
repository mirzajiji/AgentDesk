#if os(macOS)
import Foundation
import XCTest

final class BugEditorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testTicketReviewUnlinkHistoryAndArchiveSurviveRelaunch() {
        let app = application(); app.launch(); createProject(app)
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 908, dy: 718)))
        XCTAssertLessThanOrEqual(window.frame.width, 950); XCTAssertLessThanOrEqual(window.frame.height, 760)
        app.typeKey("k", modifierFlags: .command)
        replace(app.textFields["command.search"], "bug registry", app)
        app.typeKey(.return, modifierFlags: [])
        let title = app.staticTexts["bugs.title"]; XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(title.frame.minY - app.sheets.firstMatch.frame.minY, 36)
        XCTAssertLessThanOrEqual(app.sheets.firstMatch.frame.maxY, window.frame.maxY - 8, "window=\(window.frame), sheet=\(app.sheets.firstMatch.frame)")
        click("bugs.create", app)
        replace(app.textFields["bug.title"], "Synthetic ticket bug", app)
        replace(app.textFields["bug.reason"], "Reviewed report", app)
        tab("Ticket & Links", app)
        replace(app.textFields["bug.ticket.key"], "invalid", app)
        click("bug.review", app); XCTAssertTrue(app.staticTexts["bug.editor.error"].waitForExistence(timeout: 5))
        replace(app.textFields["bug.ticket.key"], "SYN-42", app)
        replace(app.textFields["bug.ticket.url"], "https://example.test/browse/SYN-42", app)
        click("bug.review", app); XCTAssertTrue(app.buttons["bug.publish"].isHittable)
        XCTAssertTrue(app.buttons["bug.cancel"].isHittable)
        XCTAssertLessThanOrEqual(app.sheets.firstMatch.frame.maxY, window.frame.maxY - 8)
        click("bug.review.back", app); click("bug.review", app); click("bug.publish", app)
        waitValue("Synthetic ticket bug", id: "bug.detail.title", app)
        let statusFilter = app.popUpButtons["bugs.filter.status"]
        let environmentFilter = app.popUpButtons["bugs.filter.environment"]
        let ticketFilter = app.popUpButtons["bugs.filter.ticket"]
        let archivedFilter = app.checkBoxes["bugs.filter.archived"]
        XCTAssertEqual(statusFilter.frame.midY, environmentFilter.frame.midY, accuracy: 4)
        XCTAssertEqual(ticketFilter.frame.midY, archivedFilter.frame.midY, accuracy: 4)
        XCTAssertLessThanOrEqual(ticketFilter.frame.maxY - statusFilter.frame.minY, 72)
        let detailTitle = app.staticTexts["bug.detail.title"]
        XCTAssertLessThanOrEqual(detailTitle.frame.minY - ticketFilter.frame.maxY, 40)
        XCTAssertLessThanOrEqual(detailTitle.frame.minY - app.sheets.firstMatch.frame.minY, 210)
        let layoutShot = XCTAttachment(screenshot: window.screenshot())
        layoutShot.name = "Compact selected bug with two filter rows"
        layoutShot.lifetime = .keepAlways; add(layoutShot)
        click("bug.edit", app); tab("Ticket & Links", app)
        replace(app.textFields["bug.ticket.key"], "", app); replace(app.textFields["bug.ticket.url"], "", app)
        replace(app.textFields["bug.reason"], "Reviewed unlink", app)
        click("bug.review", app); waitValue("None", id: "bug.change.ticket", app)
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Native bug ticket unlink review"; shot.lifetime = .keepAlways; add(shot)
        click("bug.publish", app); waitValue("Viewing v2 · open · reported", id: "bug.detail.version", app)
        app.terminate(); app.launch(); click("project.bugs.Bug project", app)
        let row = app.staticTexts["Synthetic ticket bug"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.click()
        choose("bugs.version", "v1", app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "SYN-42"),
            object: app.staticTexts["bug.detail.ticket"])], timeout: 5), .completed)
        click("bug.edit", app); choose("bug.status", "Archived", app, scroll: "bug.behavior.scroll")
        replace(app.textFields["bug.reason"], "Reviewed archive", app); click("bug.review", app); click("bug.publish", app)
        XCTAssertTrue(app.staticTexts["No matching bugs"].waitForExistence(timeout: 5))
        choose("bugs.filter.status", "Archived", app)
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.click()
        waitValue("Viewing v3 · archived · reported", id: "bug.detail.version", app)
    }

    @MainActor func testCancelledDraftAndBlockedRelationshipNavigation() {
        let app = application(); app.launch(); createProject(app); click("project.bugs.Bug project", app)
        click("bugs.create", app); replace(app.textFields["bug.title"], "Cancelled draft", app)
        replace(app.textFields["bug.reason"], "Review only", app); click("bug.review", app); click("bug.cancel", app)
        XCTAssertTrue(app.staticTexts["No matching bugs"].waitForExistence(timeout: 5))
        click("bugs.create", app); replace(app.textFields["bug.title"], "Synthetic upstream", app)
        replace(app.textFields["bug.reason"], "Reviewed upstream", app); click("bug.review", app); click("bug.publish", app)
        waitValue("Synthetic upstream", id: "bug.detail.title", app)
        let upstream = app.staticTexts["bug.detail.id"].value as! String
        click("bugs.create", app); replace(app.textFields["bug.title"], "Synthetic downstream", app)
        choose("bug.assessment", "Blocked", app, scroll: "bug.behavior.scroll")
        replace(app.textFields["bug.reason"], "Blocked by upstream", app)
        tab("Ticket & Links", app); choose("bug.relationship.kind", "Blocked by", app, scroll: "bug.links.scroll")
        replace(app.textFields["bug.relationship.target"], upstream, app, scroll: "bug.links.scroll")
        click("bug.relationship.add", app, scroll: "bug.links.scroll"); click("bug.review", app); click("bug.publish", app)
        waitValue("Synthetic downstream", id: "bug.detail.title", app)
        let downstream = app.staticTexts["bug.detail.id"].value as! String
        click("bug.link.blockedBy.\(upstream)", app, scroll: "bug.detail.scroll")
        waitValue("Synthetic upstream", id: "bug.detail.title", app)
        click("bug.incoming.blockedBy.\(downstream)", app, scroll: "bug.detail.scroll")
        waitValue("Synthetic downstream", id: "bug.detail.title", app)
        XCTAssertFalse(app.staticTexts["Cancelled draft"].exists)
    }

    @MainActor func testCoverageSubjectReviewPersistsWithoutClaimingExecution() {
        let app = application(); app.launch(); createProject(app)
        click("project.requirements.Bug project", app); click("requirements.create", app)
        replace(app.textFields["requirement.id"], "synthetic-rule", app, scroll: "requirement.editor.scroll")
        choose("requirement.status", "Active", app, scroll: "requirement.editor.scroll")
        replace(app.textViews["requirement.description"], "Synthetic required behavior", app, scroll: "requirement.editor.scroll")
        replace(app.textViews["requirement.reason"], "Reviewed requirement", app, scroll: "requirement.editor.scroll")
        click("requirement.review", app); click("requirement.publish", app)
        waitValue("Active version: v1", id: "requirements.active", app); click("requirements.done", app)
        click("project.bugs.Bug project", app)
        click("bugs.create", app); replace(app.textFields["bug.title"], "Coverage association", app)
        replace(app.textFields["bug.reason"], "Reviewed coverage subject", app)
        tab("Ticket & Links", app)
        let editLinks = app.checkBoxes["bug.requirements.edit"]
        reveal(editLinks, app, "bug.links.scroll"); editLinks.click()
        click("trace.link.add", app, scroll: "bug.links.scroll")
        replace(app.textFields["trace.link.id"], "synthetic-rule", app, scroll: "bug.links.scroll")
        replace(app.textFields["bug.coverage.id"], "synthetic-test", app, scroll: "bug.links.scroll")
        click("bug.coverage.add", app, scroll: "bug.links.scroll")
        click("bug.review", app)
        let change = app.staticTexts["bug.change.coveredBy"]
        XCTAssertTrue(change.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "synthetic-test"), object: change)], timeout: 5), .completed)
        click("bug.publish", app); waitValue("Coverage association", id: "bug.detail.title", app)
        app.terminate(); app.launch(); click("project.bugs.Bug project", app)
        let row = app.staticTexts["Coverage association"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.click(); click("bug.edit", app)
        tab("Ticket & Links", app)
        let stored = app.scrollViews["bug.links.scroll"].staticTexts.containing(NSPredicate(format: "value CONTAINS %@", "synthetic-test")).firstMatch
        XCTAssertTrue(stored.waitForExistence(timeout: 5)); reveal(stored, app, "bug.links.scroll")
        let shot = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        shot.name = "Persisted native bug coverage association"; shot.lifetime = .keepAlways; add(shot)
        click("bug.cancel", app); click("bugs.done", app)
        click("project.traceability.Bug project", app)
        replace(app.textFields["trace.impact.requirement"], "synthetic-rule", app)
        click("trace.impact.inspect", app)
        let review = app.buttons["Review Bug"].firstMatch
        XCTAssertTrue(review.waitForExistence(timeout: 5)); review.click()
        XCTAssertTrue(app.staticTexts["bug.editor.title"].waitForExistence(timeout: 5))
        tab("Ticket & Links", app)
        XCTAssertTrue(app.checkBoxes["bug.requirements.edit"].exists)
        click("bug.cancel", app)
    }

    @MainActor private func application() -> XCUIApplication {
        let app = XCUIApplication(); app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]; return app
    }

    @MainActor func testBrowserReviewAndJSONStayWithinShortWindow() {
        let app = application(); app.launch(); createProject(app)
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 908, dy: 618)))
        XCTAssertLessThanOrEqual(window.frame.height, 660)
        click("project.bugs.Bug project", app)
        XCTAssertLessThanOrEqual(app.sheets.firstMatch.frame.maxY, window.frame.maxY - 8)
        click("bugs.create", app)
        replace(app.textFields["bug.title"], "Short window report", app)
        replace(app.textFields["bug.reason"], "Reviewed compact report", app)
        click("bug.advanced", app)
        XCTAssertTrue(app.textViews["bug.json"].waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(app.sheets.firstMatch.frame.maxY, window.frame.maxY - 8)
        click("bug.json.apply", app)
        click("bug.review", app)
        XCTAssertTrue(app.buttons["bug.publish"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["bug.publish"].isHittable); XCTAssertTrue(app.buttons["bug.cancel"].isHittable)
        XCTAssertLessThanOrEqual(app.sheets.firstMatch.frame.maxY, window.frame.maxY - 8)
        let shot = XCTAttachment(screenshot: window.screenshot())
        shot.name = "Bug review contained in short native window"; shot.lifetime = .keepAlways; add(shot)
    }

    @MainActor func testObservedAssessmentRequiresExplicitSourceDeclaration() {
        let app = application(); app.launch(); createProject(app); click("project.bugs.Bug project", app)
        click("bugs.create", app); replace(app.textFields["bug.title"], "Synthetic observation", app)
        choose("bug.assessment", "Observed", app, scroll: "bug.behavior.scroll")
        replace(app.textViews["bug.root"], "Synthetic callback state", app, scroll: "bug.behavior.scroll")
        replace(app.textViews["bug.expected"], "Supplied expected state", app, scroll: "bug.behavior.scroll")
        replace(app.textViews["bug.actual"], "User-attested actual state", app, scroll: "bug.behavior.scroll")
        replace(app.textFields["bug.reason"], "Reviewed observation", app)
        click("bug.review", app); XCTAssertTrue(app.staticTexts["bug.editor.error"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["bug.publish"].exists)
        tab("Sources & Details", app)
        replace(app.textFields["bug.source.label"], "User-attested synthetic observation", app, scroll: "bug.sources.scroll")
        choose("bug.source.origin", "Observed (user-attested)", app, scroll: "bug.sources.scroll")
        click("bug.source.add", app, scroll: "bug.sources.scroll")
        click("bug.review", app); click("bug.publish", app)
        waitValue("Viewing v1 · open · observed", id: "bug.detail.version", app)
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@", "User-attested synthetic observation"),
            object: app.staticTexts["bug.detail.sources"])], timeout: 5), .completed)
    }
    @MainActor private func createProject(_ app: XCUIApplication) {
        click("workspace.create.empty", app); replace(app.textFields["catalog.name"], "Bug workspace", app); click("catalog.save", app)
        click("project.create.empty", app); replace(app.textFields["catalog.name"], "Bug project", app); click("catalog.save", app)
    }
    @MainActor private func tab(_ title: String, _ app: XCUIApplication) {
        let item = app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.click()
    }
    @MainActor private func click(_ id: String, _ app: XCUIApplication, scroll: String? = nil) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)], timeout: 5), .completed)
        if let scroll { reveal(button, app, scroll) }; button.click()
    }
    @MainActor private func replace(_ element: XCUIElement, _ text: String, _ app: XCUIApplication, scroll: String? = nil) {
        XCTAssertTrue(element.waitForExistence(timeout: 5)); if let scroll { reveal(element, app, scroll) }
        element.click(); element.typeKey("a", modifierFlags: .command)
        if text.isEmpty { element.typeKey(.delete, modifierFlags: []) } else { element.typeText(text) }
    }
    @MainActor private func choose(_ id: String, _ value: String, _ app: XCUIApplication, scroll: String? = nil) {
        let picker = app.popUpButtons[id]; XCTAssertTrue(picker.waitForExistence(timeout: 5))
        if let scroll { reveal(picker, app, scroll) }; picker.click(); app.menuItems[value].click()
    }
    @MainActor private func reveal(_ element: XCUIElement, _ app: XCUIApplication, _ id: String) {
        let scroll = app.scrollViews[id]
        for _ in 0..<30 {
            if element.isHittable && element.frame.minY >= scroll.frame.minY && element.frame.maxY <= scroll.frame.maxY { return }
            scroll.scroll(byDeltaX: 0, deltaY: element.frame.minY < scroll.frame.minY ? -150 : 150)
        }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func waitValue(_ value: String, id: String, _ app: XCUIApplication) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value),
            object: app.staticTexts[id])], timeout: 10), .completed)
    }
}
#endif
