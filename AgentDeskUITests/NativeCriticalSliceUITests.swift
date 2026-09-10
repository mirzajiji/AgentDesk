#if os(macOS)
import Foundation
import XCTest

/// Explicit live acceptance only. Ordinary test runs never contact Codex.
final class NativeCriticalSliceUITests: XCTestCase {
    @MainActor
    func testFreshNativeProjectExecutesReviewedCodexRunAndReopensEvidence() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["AGENTDESK_LIVE_ACCEPTANCE"] == "1",
                          "Requires explicit live Codex acceptance opt-in and an existing signed-in CLI.")
        continueAfterFailure = false
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDesk live acceptance \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        let expected = "AgentDesk acceptance evidence \(UUID().uuidString)"
        let source = repository.appendingPathComponent("evidence.txt")
        try Data(expected.utf8).write(to: source)
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
        git.arguments = ["init", "--initial-branch=main"]
        git.currentDirectoryURL = repository
        git.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        git.standardOutput = FileHandle.nullDevice; git.standardError = FileHandle.nullDevice
        try git.run(); git.waitUntilExit(); XCTAssertEqual(git.terminationStatus, 0)

        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        // Deliberately do not set AGENTDESK_TEST_RUN_MODE: this must use the real signed helper.
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch(); defer { app.terminate() }
        click("workspace.create.empty", in: app); saveName("Live acceptance workspace", in: app)
        click("project.create.empty", in: app); saveName("Live acceptance project", in: app)
        click("project.agents.Live acceptance project", in: app)
        click("agent.create", in: app)
        replace(app.textFields["agent.name"], with: "Evidence reviewer")
        replace(app.textViews["agent.instructions"], with: "Review synthetic repository evidence only.")
        click("agent.save", in: app)
        click("agent.edit.Evidence reviewer", in: app)
        let instructions = "Read only evidence.txt in the selected repository. Do not modify files or inspect other locations. Return its exact contents without commentary."
        replace(app.textViews["agent.instructions"], with: instructions)
        click("agent.save", in: app)
        XCTAssertTrue(app.staticTexts["Version 2"].waitForExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])

        click("project.setup.Live acceptance project", in: app)
        for level in ["workspace", "project"] {
            let edit = app.buttons["execution.edit.\(level)"]
            XCTAssertTrue(edit.waitForExistence(timeout: 5))
            XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: edit)], timeout: 5), .completed)
            edit.click(); click("execution.save", in: app)
            XCTAssertTrue(app.staticTexts["execution.saved.\(level)"].waitForExistence(timeout: 5))
        }
        click("project.repository.choose", in: app)
        XCTAssertTrue(app.buttons["Use Repository"].waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let folder = app.textFields.firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5)); folder.typeText(repository.path + "\n")
        app.buttons["Use Repository"].click()
        let access = app.descendants(matching: .any)["project.repository.access"].firstMatch
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Read-only access verified"), object: access)], timeout: 10), .completed)
        click("project.setup.done", in: app)

        openConsole(in: app)
        click("run.context.review", in: app)
        let task = app.textViews["run.task"]; reveal(task, in: app)
        task.click(); task.typeText("Read evidence.txt and return its exact contents. Make no changes.")
        consoleClick("run.prepare", in: app)
        XCTAssertTrue(app.buttons["run.start"].waitForExistence(timeout: 20), diagnostic(app))
        XCTAssertEqual(app.buttons["run.start"].label, "Approve and Start")
        XCTAssertFalse(app.staticTexts["run.evidence.content"].exists)
        consoleClick("run.start", in: app)
        let running = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "running"), object: app.staticTexts["run.state"])
        XCTAssertEqual(XCTWaiter.wait(for: [running], timeout: 15), .completed, diagnostic(app))
        XCTAssertTrue(app.staticTexts["Collect evidence"].exists, "The native progress plan must be visible during execution")
        let completed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "completed"), object: app.staticTexts["run.state"])
        XCTAssertEqual(XCTWaiter.wait(for: [completed], timeout: 120), .completed, diagnostic(app))
        let result = app.staticTexts["run.evidence.content"]
        XCTAssertTrue(result.waitForExistence(timeout: 10), diagnostic(app))
        XCTAssertEqual((result.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), expected)
        XCTAssertEqual(try String(contentsOf: source, encoding: .utf8), expected)
        reveal(result, in: app)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Real Codex result in fresh native project"; attachment.lifetime = .keepAlways; add(attachment)
        let snapshots = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "run.evidence.repositorySnapshot."))
        XCTAssertEqual(snapshots.count, 2, "The real repository adapter must record before and after observations")
        let after = snapshots.element(boundBy: 1); reveal(after, in: app); after.click()
        let observed = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value CONTAINS %@ AND value CONTAINS %@", "unchangedPreexisting", "evidence.txt"), object: result)
        XCTAssertEqual(XCTWaiter.wait(for: [observed], timeout: 5), .completed)
        click("run.console.done", in: app)
        app.terminate(); app.launch(); openConsole(in: app)
        click("run.history.open", in: app)
        let saved = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "run.history.item.")).firstMatch
        XCTAssertTrue(saved.waitForExistence(timeout: 10)); reveal(saved, in: app); saved.click()
        let output = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "run.evidence.output.")).firstMatch
        XCTAssertTrue(output.waitForExistence(timeout: 5)); reveal(output, in: app); output.click()
        XCTAssertTrue(result.waitForExistence(timeout: 10))
        XCTAssertEqual((result.value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), expected)
    }

    @MainActor private func openConsole(in app: XCUIApplication) {
        click("project.run.Live acceptance project", in: app)
        let agent = app.popUpButtons["run.agent"]
        XCTAssertTrue(agent.waitForExistence(timeout: 5)); agent.click(); app.menuItems["Evidence reviewer"].click()
    }
    @MainActor private func saveName(_ name: String, in app: XCUIApplication) {
        replace(app.textFields["catalog.name"], with: name); click("catalog.save", in: app)
    }
    @MainActor private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(text)
    }
    @MainActor private func click(_ id: String, in app: XCUIApplication) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 5)); button.click()
    }
    @MainActor private func consoleClick(_ id: String, in app: XCUIApplication) {
        let button = app.buttons[id]; XCTAssertTrue(button.waitForExistence(timeout: 5)); reveal(button, in: app); button.click()
    }
    @MainActor private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        let scroll = app.scrollViews["run.console.scroll"]
        for _ in 0..<12 {
            if element.exists && element.isHittable && element.frame.minY >= scroll.frame.minY && element.frame.maxY <= scroll.frame.maxY { return }
            scroll.scroll(byDeltaX: 0, deltaY: element.exists && element.frame.minY < scroll.frame.minY ? -150 : 150)
        }
        XCTAssertTrue(element.isHittable)
    }
    @MainActor private func diagnostic(_ app: XCUIApplication) -> String {
        "State: \(String(describing: app.staticTexts["run.state"].value)); error: \(String(describing: app.staticTexts["run.console.error"].value))"
    }
}
#endif
