#if os(macOS)
import Foundation
import XCTest

final class ProjectRunConsoleUITests: XCTestCase {
    @MainActor
    func testSavedDiffPreservesLinesInLargeNativeWindow() throws {
        continueAfterFailure = false
        let app = fixture("diff"); app.launch()
        let open = app.buttons["project.run.Synthetic run project"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 1398, dy: 898)))
        XCTAssertGreaterThanOrEqual(window.frame.width, 1300); XCTAssertGreaterThanOrEqual(window.frame.height, 850)
        openFixture(in: app); prepare(in: app); click("run.start", in: app)
        let content = app.staticTexts["run.evidence.content"]
        XCTAssertTrue(content.waitForExistence(timeout: 10))
        let diff = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "run.evidence.diff.")).firstMatch
        XCTAssertTrue(diff.waitForExistence(timeout: 5)); reveal(diff, in: app); diff.click()
        let expected = "diff --git a/synthetic.txt b/synthetic.txt\n--- a/synthetic.txt\n+++ b/synthetic.txt\n@@ -1 +1 @@\n-old synthetic line\n+new synthetic line\n"
        let value = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", expected), object: content)
        XCTAssertEqual(XCTWaiter.wait(for: [value], timeout: 5), .completed)
        reveal(content, in: app)
        let scroll = app.scrollViews["run.console.scroll"]
        for _ in 0..<8 where content.frame.maxY > scroll.frame.maxY { scroll.scroll(byDeltaX: 0, deltaY: 150) }
        XCTAssertLessThanOrEqual(content.frame.maxY, scroll.frame.maxY)
        XCTAssertTrue(app.buttons["run.console.done"].isHittable)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Native stored diff in large window"; attachment.lifetime = .keepAlways; add(attachment)
    }
    @MainActor
    func testRejectPreparedRunProducesNoProviderOutput() throws {
        continueAfterFailure = false
        let app = fixture("success"); app.launch(); openFixture(in: app); prepare(in: app)
        click("run.reject", in: app)
        waitForState("cancelled", in: app)
        XCTAssertFalse(app.buttons["run.start"].exists)
        XCTAssertFalse(app.staticTexts["run.evidence.content"].exists)
        XCTAssertTrue(app.buttons["run.console.done"].isHittable)
        app.buttons["run.console.done"].click()
        XCTAssertTrue(app.buttons["project.run.Synthetic run project"].isHittable)
    }

    @MainActor
    func testCompactConsoleCanCancelActiveRun() throws {
        continueAfterFailure = false
        let app = fixture("quiet"); app.launch()
        let open = app.buttons["project.run.Synthetic run project"]
        XCTAssertTrue(open.waitForExistence(timeout: 10))
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        corner.press(forDuration: 0.2, thenDragTo: window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 908, dy: 718)))
        XCTAssertLessThanOrEqual(window.frame.width, 950); XCTAssertLessThanOrEqual(window.frame.height, 760)
        openFixture(in: app)
        XCTAssertLessThanOrEqual(app.sheets.firstMatch.frame.height, window.frame.height - 40)
        prepare(in: app); click("run.start", in: app)
        click("run.cancel", in: app); waitForState("cancelled", in: app)
        XCTAssertFalse(app.buttons["run.cancel"].exists)
        XCTAssertTrue(app.buttons["run.console.done"].isHittable)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Compact console after cancellation"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["run.console.done"].click()
    }

    @MainActor
    func testClosingActiveConsoleWaitsForCancellationAndReleasesProject() throws {
        continueAfterFailure = false
        let app = fixture("quiet"); app.launch(); openFixture(in: app); prepare(in: app)
        click("run.start", in: app)
        XCTAssertTrue(app.buttons["run.cancel"].waitForExistence(timeout: 5))
        app.buttons["run.console.done"].click()
        let stop = app.windows.firstMatch.buttons["Stop and Close"]
        XCTAssertTrue(stop.waitForExistence(timeout: 5)); stop.click()
        XCTAssertTrue(app.buttons["run.console.done"].waitForNonExistence(timeout: 10))
        openFixture(in: app)
        app.buttons["run.history.open"].click()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "run.history.item.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); XCTAssertTrue(saved.label.contains("cancelled"))
        prepare(in: app)
        XCTAssertTrue(app.buttons["run.start"].waitForExistence(timeout: 10), "The previous session must release project ownership")
        click("run.reject", in: app); waitForState("cancelled", in: app)
    }

    @MainActor private func prepare(in app: XCUIApplication) {
        click("run.context.review", in: app)
        let editor = app.textViews["run.task"]; reveal(editor, in: app)
        editor.click(); editor.typeText("Inspect synthetic files")
        click("run.prepare", in: app)
        XCTAssertTrue(app.buttons["run.start"].waitForExistence(timeout: 10))
    }
    @MainActor private func waitForState(_ state: String, in app: XCUIApplication) {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", state), object: app.staticTexts["run.state"])
        XCTAssertEqual(XCTWaiter.wait(for: [expected], timeout: 10), .completed)
    }
    @MainActor
    func testApproveCompletesAndSavedResultReopensAfterLaunch() throws {
        continueAfterFailure = false
        let app = fixture("success"); app.launch(); openFixture(in: app)
        app.buttons["run.context.review"].click()
        let task = app.textViews["run.task"]; task.click(); task.typeText("Inspect the synthetic fixture")
        click("run.prepare", in: app)
        let start = app.buttons["run.start"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["run.evidence.content"].exists)
        click("run.start", in: app)
        let result = app.staticTexts["run.evidence.content"]
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        let text = try XCTUnwrap(result.value as? String)
        XCTAssertTrue(text.contains("Synthetic result: reviewed files."))
        XCTAssertFalse(text.contains("synthetic-ui-result-secret"))
        XCTAssertTrue(text.contains("[REDACTED]"))
        app.buttons["run.console.done"].click(); app.terminate(); app.launch(); openFixture(in: app)
        app.buttons["run.history.open"].click()
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "run.history.item.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); reveal(saved, in: app); saved.click()
        let output = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "run.evidence.output.")).firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 5)); reveal(output, in: app); output.click()
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual(result.value as? String, text)
        reveal(result, in: app)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Saved native result after relaunch"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor private func fixture(_ mode: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchEnvironment["AGENTDESK_TEST_RUN_MODE"] = mode
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        return app
    }
    @MainActor private func openFixture(in app: XCUIApplication) {
        let open = app.buttons["project.run.Synthetic run project"]
        XCTAssertTrue(open.waitForExistence(timeout: 10)); open.click()
        let agent = app.popUpButtons["run.agent"]
        XCTAssertTrue(agent.waitForExistence(timeout: 5)); agent.click()
        app.menuItems["Synthetic reviewer"].click()
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["run.console.scroll"]
        for _ in 0..<8 {
            if element.exists && element.isHittable && element.frame.minY >= scroll.frame.minY && element.frame.maxY <= scroll.frame.maxY { return }
            let direction = element.exists && element.frame.minY < scroll.frame.minY ? -150.0 : 150.0
            scroll.scroll(byDeltaX: 0, deltaY: direction)
        }
        if !element.isHittable {
            let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
            attachment.name = "Console scroll diagnostic"; attachment.lifetime = .keepAlways; add(attachment)
        }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func click(_ identifier: String, in app: XCUIApplication) {
        let button = app.buttons[identifier]
        XCTAssertTrue(button.waitForExistence(timeout: 5)); reveal(button, in: app); button.click()
    }
    @MainActor
    func testEmptyConsoleRequiresContextAndClosesWithKeyboard() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        let workspace = app.buttons["workspace.create.empty"]
        XCTAssertTrue(workspace.waitForExistence(timeout: 5)); workspace.click()
        saveName("Synthetic workspace", in: app)
        let project = app.buttons["project.create.empty"]
        XCTAssertTrue(project.waitForExistence(timeout: 5)); project.click()
        saveName("Synthetic console", in: app)
        let open = app.buttons["project.run.Synthetic console"]
        XCTAssertTrue(open.waitForExistence(timeout: 5)); open.click()
        let prepare = app.buttons["run.prepare"]
        XCTAssertTrue(prepare.waitForExistence(timeout: 5)); XCTAssertFalse(prepare.isEnabled)
        XCTAssertFalse(app.buttons["run.context.review"].isEnabled)
        let editor = app.textViews["run.task"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.click(); editor.typeText("Inspect synthetic files")
        XCTAssertFalse(prepare.isEnabled, "A task alone must not bypass context review")
        XCTAssertFalse(app.buttons["run.start"].exists)
        XCTAssertTrue(app.buttons["run.console.done"].isHittable)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Native console requires reviewed context"; attachment.lifetime = .keepAlways; add(attachment)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(prepare.waitForNonExistence(timeout: 5))
        XCTAssertTrue(open.isHittable)
    }
    @MainActor private func saveName(_ value: String, in app: XCUIApplication) {
        let field = app.textFields["catalog.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeText(value)
        app.buttons["catalog.save"].click()
    }
}
#endif
