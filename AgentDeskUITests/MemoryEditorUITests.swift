#if os(macOS)
import Foundation
import XCTest

final class MemoryEditorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor func testReviewedNotePromotionAndHistorySurviveRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        click("workspace.create.empty", app); name("Memory workspace", app)
        click("project.create.empty", app); name("Memory project", app)
        click("project.memory.Memory project", app)
        let title = app.staticTexts["memory.browser.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        XCTAssertLessThanOrEqual(title.frame.minY - app.sheets.firstMatch.frame.minY, 36)
        click("memory.create", app)
        replace(app.textFields["memory.title"], "Synthetic note", app)
        replace(app.textViews["memory.body"], "Original synthetic memory", app)
        replace(app.textFields["memory.reason"], "Initial reviewed note", app)
        click("memory.review", app)
        XCTAssertTrue(app.staticTexts["memory.proposed.version"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["memory.publish"].isHittable)
        click("memory.review.back", app)
        click("memory.review", app); click("memory.publish", app)
        waitContent("Original synthetic memory", app)
        click("memory.edit", app)
        choose("memory.kind", "Confirmed", app)
        choose("memory.topic", "Architecture", app)
        replace(app.textViews["memory.body"], "Confirmed synthetic memory", app)
        replace(app.textFields["memory.reason"], "Reviewed confirmation", app)
        click("memory.review", app)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Native memory review with reachable actions"; attachment.lifetime = .keepAlways; add(attachment)
        click("memory.publish", app); waitContent("Confirmed synthetic memory", app)
        choose("memory.version", "v1", app); waitContent("Original synthetic memory", app)
        app.terminate(); app.launch(); click("project.memory.Memory project", app)
        let row = app.staticTexts["Synthetic note"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.click()
        waitContent("Confirmed synthetic memory", app)
        choose("memory.version", "v1", app); waitContent("Original synthetic memory", app)
    }

    @MainActor private func name(_ name: String, _ app: XCUIApplication) {
        replace(app.textFields["catalog.name"], name, app); click("catalog.save", app)
    }

    @MainActor func testCancelledReviewAndIgnoredInboxFilters() {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        click("workspace.create.empty", app); name("Inbox workspace", app)
        click("project.create.empty", app); name("Inbox project", app)
        app.typeKey("k", modifierFlags: .command)
        replace(app.textFields["command.search"], "inbox project memory", app)
        app.typeKey(.return, modifierFlags: [])
        click("memory.create", app)
        replace(app.textFields["memory.title"], "Cancelled synthetic draft", app)
        replace(app.textViews["memory.body"], "Unpublished content", app)
        replace(app.textFields["memory.reason"], "Review only", app)
        click("memory.review", app); click("memory.cancel", app)
        XCTAssertTrue(app.staticTexts["No matching memory"].waitForExistence(timeout: 5))
        click("memory.create", app)
        replace(app.textFields["memory.title"], "Synthetic inbox", app)
        choose("memory.kind", "Inbox", app)
        replace(app.textViews["memory.body"], "Unclassified synthetic finding", app)
        replace(app.textFields["memory.reason"], "Reviewed inbox capture", app)
        click("memory.review", app); click("memory.publish", app)
        waitContent("Unclassified synthetic finding", app)
        click("memory.edit", app); choose("memory.disposition", "Ignored", app)
        replace(app.textFields["memory.reason"], "Reviewed dismissal", app)
        click("memory.review", app); click("memory.publish", app)
        XCTAssertTrue(app.staticTexts["No matching memory"].waitForExistence(timeout: 5))
        app.checkBoxes["memory.filter.inactive"].click()
        let row = app.staticTexts["Synthetic inbox"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.click()
        waitContent("Unclassified synthetic finding", app)
        replace(app.textFields["memory.search"], "absent synthetic phrase", app)
        XCTAssertTrue(app.staticTexts["No matching memory"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Cancelled synthetic draft"].exists)
    }
    @MainActor private func click(_ id: String, _ app: XCUIApplication) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)], timeout: 5), .completed)
        button.click()
    }
    @MainActor private func reveal(_ element: XCUIElement, _ app: XCUIApplication) {
        let scroll = app.scrollViews["memory.editor.scroll"]
        guard scroll.exists else { return }
        for _ in 0..<12 {
            if element.isHittable && element.frame.minY >= scroll.frame.minY && element.frame.maxY <= scroll.frame.maxY { return }
            scroll.scroll(byDeltaX: 0, deltaY: element.frame.minY < scroll.frame.minY ? -150 : 150)
        }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func replace(_ element: XCUIElement, _ value: String, _ app: XCUIApplication) {
        XCTAssertTrue(element.waitForExistence(timeout: 5)); reveal(element, app)
        element.click(); element.typeKey("a", modifierFlags: .command); element.typeText(value)
    }
    @MainActor private func choose(_ id: String, _ value: String, _ app: XCUIApplication) {
        let picker = app.popUpButtons[id]; XCTAssertTrue(picker.waitForExistence(timeout: 5)); reveal(picker, app)
        picker.click(); app.menuItems[value].click()
    }
    @MainActor private func waitContent(_ value: String, _ app: XCUIApplication) {
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value),
            object: app.staticTexts["memory.content"])], timeout: 10), .completed)
    }
}
#endif
