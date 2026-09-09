import XCTest
#if os(iOS)
import UIKit
#endif

final class AgentDeskUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    @MainActor
    func testLaunchShowsTruthfulEmptyState() {
        let app = XCUIApplication()
        #if os(macOS)
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()
        #if os(macOS)
        XCTAssertTrue(app.staticTexts["No workspaces yet"].waitForExistence(timeout: 5))
        #else
        XCTAssertTrue(app.staticTexts["No Mac connected"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Run"].exists)
        #endif
        XCTAssertFalse(app.staticTexts["Hello, world!"].exists)
    }

    #if os(macOS)
    @MainActor
    func testLaunchPresentsWindowAfterPreviousWindowWasClosed() {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        XCTAssertTrue(app.windows.firstMatch.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["No workspaces yet"].waitForExistence(timeout: 5))
    }

    @MainActor
    func testWorkspaceProjectCreationIsolationRenameAndReopen() {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["workspace.create.empty"].waitForExistence(timeout: 5))
        app.buttons["workspace.create.empty"].click()
        saveName("Personal", in: app)
        XCTAssertTrue(app.staticTexts["No projects yet"].waitForExistence(timeout: 5))
        app.buttons["project.create.empty"].click()
        saveName("AgentDesk", in: app)
        XCTAssertTrue(app.buttons["project.rename.AgentDesk"].waitForExistence(timeout: 5))
        app.buttons["project.rename.AgentDesk"].click()
        let field = app.textFields["catalog.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeKey("a", modifierFlags: .command)
        field.typeText("Native App")
        app.buttons["catalog.save"].click()
        XCTAssertTrue(app.buttons["project.rename.Native App"].waitForExistence(timeout: 5))
        app.buttons["workspace.create"].click()
        saveName("Second", in: app)
        XCTAssertTrue(app.staticTexts["No projects yet"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["project.rename.Native App"].exists)
        app.staticTexts["Personal"].firstMatch.click()
        XCTAssertTrue(app.buttons["project.rename.Native App"].waitForExistence(timeout: 5))
        app.terminate()
        app.launch()
        XCTAssertTrue(app.buttons["project.rename.Native App"].waitForExistence(timeout: 5))
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Persistent workspace and project"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testAgentInstructionsPersistAcrossEditArchiveRestoreAndRelaunch() {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["workspace.create.empty"].waitForExistence(timeout: 5))
        app.buttons["workspace.create.empty"].click()
        saveName("Personal", in: app)
        XCTAssertTrue(app.buttons["project.create.empty"].waitForExistence(timeout: 5))
        app.buttons["project.create.empty"].click()
        saveName("Agent Project", in: app)
        XCTAssertTrue(app.buttons["project.agents.Agent Project"].waitForExistence(timeout: 5))
        app.buttons["project.agents.Agent Project"].click()
        XCTAssertTrue(app.staticTexts["No agents yet"].waitForExistence(timeout: 5))
        app.buttons["agent.create"].click()
        let name = app.textFields["agent.name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.click(); name.typeKey("a", modifierFlags: .command); name.typeText("Project Helper")
        let instructions = app.textViews["agent.instructions"]
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        instructions.click(); instructions.typeKey("a", modifierFlags: .command)
        instructions.typeText("Inspect synthetic requirements and cite evidence.")
        app.buttons["agent.save"].click()
        XCTAssertTrue(app.buttons["agent.edit.Project Helper"].waitForExistence(timeout: 5))
        app.buttons["agent.edit.Project Helper"].click()
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        XCTAssertEqual(instructions.value as? String, "Inspect synthetic requirements and cite evidence.")
        instructions.click(); instructions.typeKey("a", modifierFlags: .command)
        instructions.typeText("Updated instructions with explicit unknowns.")
        app.buttons["agent.save"].click()
        XCTAssertTrue(app.staticTexts["Version 2"].waitForExistence(timeout: 5))
        app.buttons["agent.archive.Project Helper"].click()
        XCTAssertTrue(app.staticTexts["Archived"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["agent.edit.Project Helper"].isEnabled)
        app.buttons["agent.archive.Project Helper"].click()
        XCTAssertTrue(app.staticTexts["Version 4"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["project.agents.Agent Project"].waitForExistence(timeout: 5))
        app.buttons["project.agents.Agent Project"].click()
        XCTAssertTrue(app.buttons["agent.edit.Project Helper"].waitForExistence(timeout: 5))
        app.buttons["agent.edit.Project Helper"].click()
        XCTAssertTrue(instructions.waitForExistence(timeout: 5))
        XCTAssertEqual(instructions.value as? String, "Updated instructions with explicit unknowns.")
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Versioned agent instruction editor"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testWorkspaceValidationAndCancelPreserveSavedData() {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["workspace.create.empty"].waitForExistence(timeout: 5))
        app.buttons["workspace.create.empty"].click()
        saveName("Personal", in: app)
        XCTAssertTrue(app.staticTexts["No projects yet"].waitForExistence(timeout: 5))
        app.buttons["workspace.create"].click()
        saveName("personal", in: app)
        XCTAssertTrue(app.staticTexts["catalog.validation"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["That name is already used here. Choose another name."].exists)
        app.buttons["Cancel"].click()
        XCTAssertTrue(app.staticTexts["No projects yet"].exists)
        app.buttons["workspace.create"].click()
        saveName("invalid/name", in: app)
        XCTAssertTrue(app.staticTexts["catalog.validation"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].click()
        XCTAssertFalse(app.sheets.firstMatch.exists)
    }

    @MainActor
    private func saveName(_ name: String, in app: XCUIApplication) {
        let field = app.textFields["catalog.name"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(name)
        app.buttons["catalog.save"].click()
    }

    @MainActor
    func testSidebarNavigatesBetweenEmptySections() {
        let app = XCUIApplication()
        #if os(macOS)
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()
        app.staticTexts["Runs"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No runs yet"].waitForExistence(timeout: 5))
        app.staticTexts["Connections"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No connections configured"].waitForExistence(timeout: 5))
        app.staticTexts["Workspaces"].firstMatch.click()
        XCTAssertTrue(app.staticTexts["No workspaces yet"].waitForExistence(timeout: 5))
    }
    #else
    @MainActor
    func testCompanionSupportsLargestAccessibilityText() {
        let app = XCUIApplication()
        #if os(macOS)
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launchArguments += ["-UIPreferredContentSizeCategoryName",
                                UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        app.launch()
        XCTAssertTrue(app.staticTexts["No Mac connected"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["No Mac connected"].isHittable)
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = "Companion largest accessibility text"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    @MainActor
    func testCompanionRemainsDisconnectedAfterRotation() {
        let app = XCUIApplication()
        #if os(macOS)
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        #endif
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.staticTexts["No Mac connected"].waitForExistence(timeout: 5))
    }
    #endif
}
