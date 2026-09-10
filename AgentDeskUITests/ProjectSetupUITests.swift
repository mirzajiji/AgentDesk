#if os(macOS)
import Foundation
import XCTest

final class ProjectSetupUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testSetupEditorsKeepActionsReachableInCompactWindow() throws {
        let app = application(); app.launch(); createProject(in: app)
        let window = app.windows.firstMatch
        let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1)).withOffset(CGVector(dx: -2, dy: -2))
        let target = window.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: 908, dy: 718))
        corner.press(forDuration: 0.2, thenDragTo: target)
        XCTAssertLessThanOrEqual(window.frame.width, 950)
        XCTAssertLessThanOrEqual(window.frame.height, 760)
        openSetup(in: app)
        XCTAssertTrue(app.buttons["project.setup.done"].isHittable)
        app.buttons["execution.edit.workspace"].click()
        XCTAssertTrue(app.buttons["execution.save"].isHittable)
        app.buttons["execution.advanced.open"].click()
        let editor = app.textViews["execution.advanced.json"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        replace(editor, with: "{invalid")
        app.buttons["execution.advanced.apply"].click()
        XCTAssertTrue(app.staticTexts["execution.advanced.error"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["execution.advanced.apply"].isHittable)
        attach(app, name: "Compact Mac JSON validation and reachable actions")
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5))
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertFalse(app.staticTexts["execution.saved.workspace"].exists)
        XCTAssertTrue(app.buttons["project.setup.done"].isHittable)
        attach(app, name: "Compact Mac setup after keyboard cancellation")
    }

    @MainActor
    func testExecutionStartingSettingsRequireSaveAndEditsPersistAcrossLaunch() throws {
        let app = application(); app.launch(); createProject(in: app); openSetup(in: app)
        XCTAssertTrue(app.staticTexts["project.repository.empty"].exists)
        app.buttons["execution.edit.workspace"].click()
        XCTAssertTrue(app.staticTexts["Workspace Execution Settings"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertFalse(app.staticTexts["execution.saved.workspace"].exists)
        app.buttons["execution.edit.workspace"].click()
        let timeout = app.textFields["execution.timeout"].firstMatch
        XCTAssertTrue(timeout.waitForExistence(timeout: 5))
        replace(timeout, with: "0")
        app.buttons["execution.save"].click()
        XCTAssertTrue(app.staticTexts["execution.validation"].waitForExistence(timeout: 5))
        replace(timeout, with: "120")
        app.buttons["execution.save"].click()
        XCTAssertTrue(app.staticTexts["execution.saved.workspace"].waitForExistence(timeout: 5))
        app.buttons["execution.edit.project"].click()
        let model = app.textFields["execution.model"].firstMatch
        XCTAssertTrue(model.waitForExistence(timeout: 5))
        replace(model, with: "synthetic-configured-model")
        app.buttons["execution.save"].click()
        XCTAssertTrue(app.staticTexts["execution.saved.project"].waitForExistence(timeout: 5))
        app.buttons["project.setup.done"].click()
        app.terminate(); app.launch(); openSetup(in: app)
        app.buttons["execution.edit.workspace"].click()
        XCTAssertTrue(timeout.waitForExistence(timeout: 5)); XCTAssertEqual(timeout.value as? String, "120")
        app.buttons["Cancel"].click()
        app.buttons["execution.edit.project"].click()
        XCTAssertTrue(model.waitForExistence(timeout: 5)); XCTAssertEqual(model.value as? String, "synthetic-configured-model")
        app.buttons["Cancel"].click()
        attach(app, name: "Native project execution setup")
    }

    @MainActor
    func testAdvancedConstraintsValidateBeforeApplyingAndPersistAfterExplicitSave() throws {
        let app = application(); app.launch(); createProject(in: app); openSetup(in: app)
        app.buttons["execution.edit.workspace"].click()
        app.buttons["execution.advanced.open"].click()
        let editor = app.textViews["execution.advanced.json"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let original = try XCTUnwrap(editor.value as? String)
        replace(editor, with: "{invalid")
        app.buttons["execution.advanced.apply"].click()
        XCTAssertTrue(app.staticTexts["execution.advanced.error"].waitForExistence(timeout: 5))
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(original.utf8)) as? [String: Any])
        var settings = try XCTUnwrap(document["settings"] as? [String: Any])
        settings["modelIdentifier"] = "synthetic-configured-model"
        settings["allowedModelIdentifiers"] = ["synthetic-configured-model"]
        settings["outputSchema"] = ["type": "object", "properties": ["ok": ["type": "boolean"]],
                                    "required": ["ok"], "additionalProperties": false] as [String: Any]
        document["settings"] = settings
        let text = String(decoding: try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), as: UTF8.self)
        replace(editor, with: text)
        XCTAssertEqual(editor.value as? String, text, "The JSON editor must preserve typed characters exactly")
        app.buttons["execution.advanced.apply"].click()
        attach(app, name: "Advanced JSON after valid apply")
        XCTAssertTrue(editor.waitForNonExistence(timeout: 5), "Valid JSON must close the advanced sheet")
        XCTAssertTrue(app.buttons["execution.save"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textFields["execution.model"].firstMatch.value as? String, "synthetic-configured-model")
        app.buttons["execution.save"].click()
        XCTAssertTrue(app.staticTexts["execution.saved.workspace"].waitForExistence(timeout: 5))
        app.buttons["project.setup.done"].click(); app.terminate(); app.launch(); openSetup(in: app)
        app.buttons["execution.edit.workspace"].click(); app.buttons["execution.advanced.open"].click()
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let persisted = try XCTUnwrap(editor.value as? String)
        let reopened = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(persisted.utf8)) as? [String: Any])
        let reopenedSettings = try XCTUnwrap(reopened["settings"] as? [String: Any])
        XCTAssertEqual(reopenedSettings["allowedModelIdentifiers"] as? [String], ["synthetic-configured-model"])
        XCTAssertNotNil(reopenedSettings["outputSchema"])
        attach(app, name: "Advanced native execution settings")
    }

    @MainActor
    func testExternalRepositoryPickerBookmarkAccessSurvivesAppRelaunchAndRemovalKeepsFiles() throws {
        let repository = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDesk synthetic repository \(UUID().uuidString)")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repository) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Applications/Xcode.app/Contents/Developer/usr/bin/git")
        process.arguments = ["init", "--initial-branch=main"]
        process.currentDirectoryURL = repository
        process.environment = ["PATH": "/usr/bin:/bin", "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
        let app = application(); app.launch(); createProject(in: app); openSetup(in: app)
        app.buttons["project.repository.choose"].click()
        XCTAssertTrue(app.buttons["Use Repository"].waitForExistence(timeout: 5))
        app.typeKey("g", modifierFlags: [.command, .shift])
        let folder = app.textFields.firstMatch
        XCTAssertTrue(folder.waitForExistence(timeout: 5))
        folder.typeText(repository.path + "\n")
        app.buttons["Use Repository"].click()
        let access = app.descendants(matching: .any)["project.repository.access"].firstMatch
        XCTAssertTrue(access.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForVerifiedAccess(access))
        app.buttons["project.setup.done"].click()
        app.terminate(); app.launch(); openSetup(in: app)
        XCTAssertTrue(access.waitForExistence(timeout: 10)); XCTAssertTrue(waitForVerifiedAccess(access))
        XCTAssertEqual(app.staticTexts["project.repository.path"].value as? String, repository.resolvingSymlinksInPath().path)
        attach(app, name: "External repository access after relaunch")
        app.buttons["project.repository.remove"].click()
        let remove = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Remove Registration", "project.repository.remove")).firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5)); remove.click()
        XCTAssertTrue(app.staticTexts["project.repository.empty"].waitForExistence(timeout: 5))
        XCTAssertTrue(FileManager.default.fileExists(atPath: repository.appendingPathComponent(".git/HEAD").path))
    }

    @MainActor private func application() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        return app
    }
    @MainActor private func createProject(in app: XCUIApplication) {
        let create = app.buttons["workspace.create.empty"]
        XCTAssertTrue(create.waitForExistence(timeout: 5)); create.click(); saveName("Synthetic workspace", in: app)
        let project = app.buttons["project.create.empty"]
        XCTAssertTrue(project.waitForExistence(timeout: 5)); project.click(); saveName("Synthetic project", in: app)
    }
    @MainActor private func saveName(_ text: String, in app: XCUIApplication) {
        let name = app.textFields["catalog.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5)); name.click(); name.typeText(text)
        app.buttons["catalog.save"].click()
    }
    @MainActor private func openSetup(in app: XCUIApplication) {
        let setup = app.buttons["project.setup.Synthetic project"]
        XCTAssertTrue(setup.waitForExistence(timeout: 5)); setup.click()
        XCTAssertTrue(app.buttons["execution.edit.workspace"].waitForExistence(timeout: 5))
        let ready = NSPredicate(format: "enabled == true")
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: ready, object: app.buttons["execution.edit.workspace"])], timeout: 5), .completed)
    }
    @MainActor private func replace(_ field: XCUIElement, with value: String) {
        field.click(); field.typeKey("a", modifierFlags: .command); field.typeText(value)
    }
    @MainActor private func waitForVerifiedAccess(_ element: XCUIElement) -> Bool {
        let expected = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", "Read-only access verified"), object: element)
        return XCTWaiter.wait(for: [expected], timeout: 10) == .completed
    }
    @MainActor private func attach(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
#endif
