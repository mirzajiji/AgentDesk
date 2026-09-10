#if os(macOS)
import Foundation
import XCTest

final class RequirementEditorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testRequirementBrowserHeaderStaysAtTopInEmptyAndUnselectedStates() {
        let app = application(); app.launch(); createProject(in: app)
        resizeLarge(in: app)
        openRequirements(in: app)
        assertHeaderAtTop(in: app, name: "Empty requirements modal")
        click("requirements.done", in: app)
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 908, dy: 718)))
        openRequirements(in: app)
        assertHeaderAtTop(in: app, name: "Compact empty requirements modal")
        click("requirements.create", in: app); fillNew(in: app)
        click("requirement.review", in: app); click("requirement.publish", in: app)
        waitForValue("Active version: v1", id: "requirements.active", in: app)
        click("requirements.done", in: app); openRequirements(in: app)
        XCTAssertTrue(app.descendants(matching: .any)["requirement.row.synthetic-rule"].firstMatch.waitForExistence(timeout: 5))
        assertHeaderAtTop(in: app, name: "Compact unselected requirements modal")
        click("requirements.done", in: app); resizeLarge(in: app); openRequirements(in: app)
        assertHeaderAtTop(in: app, name: "Unselected requirements modal")
    }
    @MainActor
    func testTraceabilityReviewCurrentHistoricalAndArchive() {
        let app = application(); app.launch(); createProject(in: app)
        click("project.setup.Requirement project", in: app)
        for level in ["workspace", "project"] {
            click("execution.edit.\(level)", in: app); click("execution.save", in: app)
            XCTAssertTrue(app.staticTexts["execution.saved.\(level)"].waitForExistence(timeout: 5))
        }
        click("project.setup.done", in: app)
        openRequirements(in: app); click("requirements.create", in: app); fillNew(in: app)
        click("requirement.review", in: app); click("requirement.publish", in: app)
        waitForValue("Active version: v1", id: "requirements.active", in: app)
        click("requirements.done", in: app)
        click("project.traceability.Requirement project", in: app); click("trace.create", in: app)
        replace(app.textFields["trace.subject"], with: "synthetic-test", in: app, scroll: "trace.editor.scroll")
        replace(app.textFields["trace.title"], with: "Synthetic coverage", in: app, scroll: "trace.editor.scroll")
        replace(app.textFields["trace.link.id"], with: "synthetic-rule", in: app, scroll: "trace.editor.scroll")
        replace(app.textFields["trace.reason"], with: "Reviewed coverage", in: app, scroll: "trace.editor.scroll")
        click("trace.review", in: app)
        XCTAssertTrue(app.staticTexts["trace.proposed.revision"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["trace.publish"].isHittable)
        attach(app, name: "Native traceability publication review")
        click("trace.publish", in: app)
        waitForValue("Recorded v1 · Current", id: "trace.status.synthetic-rule", in: app)
        click("trace.done", in: app); openRequirements(in: app)
        app.descendants(matching: .any)["requirement.row.synthetic-rule"].firstMatch.click()
        click("requirement.edit.latest", in: app, scroll: "requirements.detail.scroll")
        replace(app.textViews["requirement.description"], with: "Updated synthetic behavior", in: app)
        replace(app.textViews["requirement.reason"], with: "Updated requirement", in: app)
        click("requirement.review", in: app); click("requirement.publish", in: app)
        waitForValue("Active version: v2", id: "requirements.active", in: app)
        click("requirements.done", in: app); click("project.traceability.Requirement project", in: app)
        let row = app.descendants(matching: .any)["trace.row.automatedTest.synthetic-test"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.click()
        waitForValue("Recorded v1 · Potentially stale", id: "trace.status.synthetic-rule", in: app)
        waitForValue("Viewing requirement v2", id: "trace.viewing.synthetic-rule", in: app)
        app.checkBoxes["trace.inspect.historical"].click()
        waitForValue("Viewing requirement v1", id: "trace.viewing.synthetic-rule", in: app)
        attach(app, name: "Native traceability historical inspection with stale status")
        click("trace.edit", in: app, scroll: "trace.detail.scroll")
        let archive = app.checkBoxes["trace.archived"]
        reveal(archive, in: app, scroll: "trace.editor.scroll"); archive.click()
        replace(app.textFields["trace.reason"], with: "Archive coverage", in: app, scroll: "trace.editor.scroll")
        click("trace.review", in: app); click("trace.publish", in: app)
        XCTAssertTrue(app.staticTexts["No matching links"].waitForExistence(timeout: 5))
        app.checkBoxes["trace.filter.archived"].click()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }
    @MainActor private func assertHeaderAtTop(in app: XCUIApplication, name: String) {
        let title = app.staticTexts["requirements.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        attach(app, name: name)
        let gap = title.frame.minY - app.sheets.firstMatch.frame.minY
        XCTAssertGreaterThanOrEqual(gap, 12)
        XCTAssertLessThanOrEqual(gap, 36, "Requirements header should keep standard top inset, actual: \(gap)")
    }

    @MainActor
    func testCommandRouteAndCancelledReviewCreateNoRequirement() {
        let app = application(); app.launch(); createProject(in: app)
        app.typeKey("k", modifierFlags: .command)
        let search = app.textFields["command.search"]
        XCTAssertTrue(search.waitForExistence(timeout: 5)); search.typeText("manage requirements")
        app.typeKey(.return, modifierFlags: [])
        click("requirements.create", in: app)
        fillNew(in: app); click("requirement.review", in: app)
        XCTAssertTrue(app.staticTexts["requirement.proposed.version"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons["requirement.publish"].label, "Create v1")
        click("requirement.cancel", in: app)
        XCTAssertTrue(app.descendants(matching: .any)["requirements.empty"].firstMatch.waitForExistence(timeout: 5))
        app.terminate(); app.launch(); openRequirements(in: app)
        XCTAssertFalse(app.descendants(matching: .any)["requirement.row.synthetic-rule"].firstMatch.exists)
    }

    @MainActor
    func testReviewedVersionsAdvancedFieldsAndHistorySurviveRelaunch() throws {
        let app = application(); app.launch(); createProject(in: app)
        resizeLarge(in: app)
        openRequirements(in: app)
        click("requirements.create", in: app); fillNew(in: app)
        click("requirement.review", in: app); click("requirement.publish", in: app)
        waitForValue("Active version: v1", id: "requirements.active", in: app)
        click("requirement.edit.latest", in: app, scroll: "requirements.detail.scroll")
        replace(app.textViews["requirement.description"], with: "Proposed synthetic behavior", in: app)
        replace(app.textViews["requirement.reason"], with: "Review a draft change", in: app)
        chooseStatus("Draft", in: app)
        click("requirement.json.open", in: app, scroll: "requirement.editor.scroll")
        let json = app.textViews["requirement.json"]
        XCTAssertTrue(json.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(json.value as? String)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        replace(json, with: "{invalid", in: app, scroll: nil)
        click("requirement.json.apply", in: app)
        XCTAssertTrue(app.staticTexts["requirement.json.error"].waitForExistence(timeout: 5))
        document["rules"] = ["A synthetic rule"]
        document["expectedBehavior"] = ["ok": true]
        document["executableValidationRules"] = [["schemaVersion": 1, "id": "expected-result", "path": [], "operation": "equals", "expected": true]]
        replace(json, with: String(decoding: try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), as: UTF8.self), in: app, scroll: nil)
        click("requirement.json.apply", in: app)
        XCTAssertTrue(json.waitForNonExistence(timeout: 5))
        click("requirement.review", in: app)
        waitForValue("Proposed version: v2", id: "requirement.proposed.version", in: app)
        XCTAssertTrue((app.staticTexts["requirement.change.Rules"].value as? String)?.contains("A synthetic rule") == true)
        XCTAssertTrue((app.staticTexts["requirement.change.Executable validation rules"].value as? String)?.contains("expected-result") == true)
        click("requirement.publish", in: app)
        waitForValue("Active version: v1", id: "requirements.active", in: app)
        waitForValue("Viewing v2 · draft", id: "requirements.viewing", in: app)
        app.terminate(); app.launch(); resizeLarge(in: app); openRequirements(in: app)
        let row = app.descendants(matching: .any)["requirement.row.synthetic-rule"].firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 5)); row.click()
        let picker = app.popUpButtons["requirements.version"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); picker.click(); app.menuItems["v1 · active"].click()
        waitForValue("Original synthetic behavior", id: "requirement.detail.Description", in: app)
        reveal(app.staticTexts["requirement.detail.Description"], in: app, scroll: "requirements.detail.scroll")
        attach(app, name: "Historical requirement remains intact after relaunch")
    }

    @MainActor
    func testCompactReviewEnvironmentRetirementAndReactivation() {
        let app = application(); app.launch(); createProject(in: app)
        click("project.setup.Requirement project", in: app)
        for level in ["workspace", "project"] {
            click("execution.edit.\(level)", in: app); click("execution.save", in: app)
            XCTAssertTrue(app.staticTexts["execution.saved.\(level)"].waitForExistence(timeout: 5))
        }
        click("project.setup.done", in: app)
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 908, dy: 718)))
        XCTAssertLessThanOrEqual(window.frame.width, 950); XCTAssertLessThanOrEqual(window.frame.height, 760)
        XCTAssertTrue(app.buttons["project.requirements.Requirement project"].isHittable)
        openRequirements(in: app); click("requirements.create", in: app); fillNew(in: app)
        let environment = app.checkBoxes["requirement.environment.Development"]
        XCTAssertTrue(environment.waitForExistence(timeout: 5)); reveal(environment, in: app, scroll: "requirement.editor.scroll"); environment.click()
        click("requirement.review", in: app)
        XCTAssertTrue(app.buttons["requirement.publish"].isHittable); XCTAssertTrue(app.buttons["requirement.cancel"].isHittable)
        XCTAssertLessThanOrEqual(app.sheets.firstMatch.frame.height, window.frame.height - 40)
        attach(app, name: "Compact native requirement review with reachable actions")
        click("requirement.publish", in: app)
        waitForValue("Active version: v1", id: "requirements.active", in: app)
        click("requirement.edit.latest", in: app, scroll: "requirements.detail.scroll")
        chooseStatus("Retired", in: app)
        replace(app.textViews["requirement.reason"], with: "Retire synthetic behavior", in: app)
        click("requirement.review", in: app); click("requirement.publish", in: app)
        waitForValue("No active version", id: "requirements.active", in: app)
        click("requirement.edit.latest", in: app, scroll: "requirements.detail.scroll")
        chooseStatus("Active", in: app)
        replace(app.textViews["requirement.reason"], with: "Reactivate reviewed behavior", in: app)
        reveal(environment, in: app, scroll: "requirement.editor.scroll")
        XCTAssertEqual((environment.value as? NSNumber)?.intValue, 1)
        click("requirement.review", in: app); click("requirement.publish", in: app)
        waitForValue("Active version: v3", id: "requirements.active", in: app)
    }

    @MainActor private func application() -> XCUIApplication {
        let app = XCUIApplication(); app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]; return app
    }
    @MainActor private func resizeLarge(in app: XCUIApplication) {
        let window = app.windows.firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1398, dy: 898)))
        // Window resizing is constrained by the attached display's logical size.
        // Keep the header assertions strict on smaller developer displays too.
        XCTAssertGreaterThanOrEqual(window.frame.width, 900)
        XCTAssertGreaterThanOrEqual(window.frame.height, 560)
        let size = XCTAttachment(string: "Requested 1398×898; actual window: \(window.frame.size)")
        size.name = "Available window size"; size.lifetime = .keepAlways; add(size)
    }
    @MainActor private func createProject(in app: XCUIApplication) {
        click("workspace.create.empty", in: app); saveName("Requirement workspace", in: app)
        click("project.create.empty", in: app); saveName("Requirement project", in: app)
    }
    @MainActor private func saveName(_ name: String, in app: XCUIApplication) {
        let field = app.textFields["catalog.name"]; XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText(name)
        click("catalog.save", in: app)
    }
    @MainActor private func openRequirements(in app: XCUIApplication) { click("project.requirements.Requirement project", in: app) }
    @MainActor private func fillNew(in app: XCUIApplication) {
        replace(app.textFields["requirement.id"], with: "synthetic-rule", in: app)
        chooseStatus("Active", in: app)
        replace(app.textViews["requirement.description"], with: "Original synthetic behavior", in: app)
        replace(app.textViews["requirement.reason"], with: "Initial reviewed requirement", in: app)
    }
    @MainActor private func chooseStatus(_ status: String, in app: XCUIApplication) {
        let picker = app.popUpButtons["requirement.status"]
        XCTAssertTrue(picker.waitForExistence(timeout: 5)); reveal(picker, in: app, scroll: "requirement.editor.scroll")
        picker.click(); app.menuItems[status].click()
    }
    @MainActor private func replace(_ element: XCUIElement, with text: String, in app: XCUIApplication, scroll: String? = "requirement.editor.scroll") {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        if let scroll { reveal(element, in: app, scroll: scroll) }
        element.click(); element.typeKey("a", modifierFlags: .command); element.typeText(text)
    }
    @MainActor private func click(_ id: String, in app: XCUIApplication, scroll: String? = nil) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: button)], timeout: 5), .completed)
        if let scroll { reveal(button, in: app, scroll: scroll) }
        button.click()
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication, scroll id: String) {
        let scroll = app.scrollViews[id]
        for _ in 0..<12 {
            if element.exists && element.isHittable && element.frame.minY >= scroll.frame.minY && element.frame.maxY <= scroll.frame.maxY { return }
            scroll.scroll(byDeltaX: 0, deltaY: element.exists && element.frame.minY < scroll.frame.minY ? -150 : 150)
        }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func waitForValue(_ value: String, id: String, in app: XCUIApplication) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: app.staticTexts[id])
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 10), .completed)
    }
    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
