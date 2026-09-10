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
        XCTAssertFalse(app.staticTexts["catalog.error"].exists)
        #else
        XCTAssertTrue(app.staticTexts["No Mac connected"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["Run"].exists)
        #endif
        XCTAssertFalse(app.staticTexts["Hello, world!"].exists)
    }

    #if os(macOS)
    @MainActor
    func testCodexSettingsHealthDisconnectAndReconnectPersistWithoutSigningOut() {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["settings.open"].waitForExistence(timeout: 5))
        app.buttons["settings.open"].click()
        let settings = app.windows["AgentDesk Settings"]
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        let health = settings.buttons["codex.refresh"]
        let ready = NSPredicate(format: "enabled == true")
        expectation(for: ready, evaluatedWith: health)
        waitForExpectations(timeout: 20)
        XCTAssertTrue(settings.buttons["codex.choose"].isEnabled)
        let attachment = XCTAttachment(screenshot: settings.screenshot())
        attachment.name = "Native Codex connection settings"; attachment.lifetime = .keepAlways; add(attachment)
        settings.buttons["codex.toggle"].click()
        XCTAssertFalse(health.isEnabled)
        XCTAssertFalse(settings.buttons["codex.login"].isEnabled)
        XCTAssertFalse(settings.buttons["codex.logout"].isEnabled)
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["settings.open"].waitForExistence(timeout: 5))
        app.buttons["settings.open"].click()
        XCTAssertTrue(settings.waitForExistence(timeout: 5))
        XCTAssertFalse(settings.buttons["codex.refresh"].isEnabled)
        settings.buttons["codex.toggle"].click()
        expectation(for: ready, evaluatedWith: settings.buttons["codex.refresh"])
        waitForExpectations(timeout: 20)
        // Actual account sign-out is deliberately not invoked by UI regression tests.
    }

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
    func testCityPayTemplateCreatesVersionedSkillAndReopensWithExamples() {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["workspace.create.empty"].waitForExistence(timeout: 5))
        app.buttons["workspace.create.empty"].click(); saveName("Synthetic workspace", in: app)
        XCTAssertTrue(app.buttons["project.create.empty"].waitForExistence(timeout: 5))
        app.buttons["project.create.empty"].click(); saveName("Report Project", in: app)
        XCTAssertTrue(app.buttons["project.agents.Report Project"].waitForExistence(timeout: 5))
        app.buttons["project.agents.Report Project"].click()
        XCTAssertTrue(app.buttons["skills.open"].waitForExistence(timeout: 5)); app.buttons["skills.open"].click()
        XCTAssertTrue(app.buttons["skill.create"].waitForExistence(timeout: 5)); app.buttons["skill.create"].click()
        XCTAssertTrue(app.buttons["skill.template.citypay"].waitForExistence(timeout: 5)); app.buttons["skill.template.citypay"].click()
        XCTAssertEqual(app.textFields["skill.name"].value as? String, "citypay-jira-bug")
        XCTAssertFalse(app.buttons["skill.template.citypay"].exists)
        XCTAssertTrue((app.textViews["skill.instructions"].value as? String)?.contains("Never guess") == true)
        app.tabs["Attachments"].click()
        XCTAssertTrue(app.staticTexts["examples/synthetic-refund.json"].exists)
        app.buttons["skill.save"].click()
        XCTAssertTrue(app.buttons["skill.edit.citypay-jira-bug"].waitForExistence(timeout: 5))
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["project.agents.Report Project"].waitForExistence(timeout: 5)); app.buttons["project.agents.Report Project"].click()
        XCTAssertTrue(app.buttons["skills.open"].waitForExistence(timeout: 5)); app.buttons["skills.open"].click()
        XCTAssertTrue(app.buttons["skill.edit.citypay-jira-bug"].waitForExistence(timeout: 5)); app.buttons["skill.edit.citypay-jira-bug"].click()
        XCTAssertTrue(app.textViews["skill.instructions"].waitForExistence(timeout: 5))
        XCTAssertTrue((app.textViews["skill.instructions"].value as? String)?.contains("template version 1") == true)
        XCTAssertFalse(app.buttons["skill.template.citypay"].exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "CityPay skill template reopened in native editor"; attachment.lifetime = .keepAlways; add(attachment)
    }

    @MainActor
    func testSkillCreationPinningPreviewAndReopen() {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["workspace.create.empty"].waitForExistence(timeout: 5))
        app.buttons["workspace.create.empty"].click(); saveName("Synthetic workspace", in: app)
        XCTAssertTrue(app.buttons["project.create.empty"].waitForExistence(timeout: 5))
        app.buttons["project.create.empty"].click(); saveName("Skill Project", in: app)
        XCTAssertTrue(app.buttons["project.agents.Skill Project"].waitForExistence(timeout: 5))
        app.buttons["project.agents.Skill Project"].click()
        XCTAssertTrue(app.buttons["skills.open"].waitForExistence(timeout: 5)); app.buttons["skills.open"].click()
        XCTAssertTrue(app.buttons["skill.create"].waitForExistence(timeout: 5)); app.buttons["skill.create"].click()
        XCTAssertTrue(app.textFields["skill.name"].waitForExistence(timeout: 5))
        app.textFields["skill.name"].click(); app.textFields["skill.name"].typeText("Evidence method")
        app.textViews["skill.instructions"].click(); app.textViews["skill.instructions"].typeText("Keep synthetic observations separate from assumptions.")
        app.tabs["Attachments"].click()
        app.buttons["skill.attachment.add"].click()
        XCTAssertTrue(app.textViews["skill.attachment.text"].waitForExistence(timeout: 5))
        app.textViews["skill.attachment.text"].click(); app.textViews["skill.attachment.text"].typeText("Synthetic example kept with this version.")
        app.buttons["skill.attachment.keep"].click()
        XCTAssertTrue(app.staticTexts["examples/example.md"].waitForExistence(timeout: 5))
        app.buttons["skill.save"].click()
        XCTAssertTrue(app.buttons["skill.edit.Evidence method"].waitForExistence(timeout: 5))
        app.buttons["skills.done"].click()
        XCTAssertTrue(app.buttons["agent.create"].waitForExistence(timeout: 5)); app.buttons["agent.create"].click()
        XCTAssertTrue(app.buttons["agent.save"].waitForExistence(timeout: 5))
        app.tabs["Skills"].click()
        let selection = app.checkBoxes["agent.skill.Evidence method"]
        XCTAssertTrue(selection.waitForExistence(timeout: 5)); selection.click()
        app.buttons["agent.save"].click()
        XCTAssertTrue(app.buttons["agent.preview.General Assistant"].waitForExistence(timeout: 5))
        app.buttons["agent.preview.General Assistant"].click()
        XCTAssertTrue(app.staticTexts["instruction.source.Skill"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Keep synthetic observations separate from assumptions."].exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Pinned skill instructions in native preview"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["instructions.preview.done"].click()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["project.agents.Skill Project"].waitForExistence(timeout: 5))
        app.buttons["project.agents.Skill Project"].click()
        XCTAssertTrue(app.buttons["agent.edit.General Assistant"].waitForExistence(timeout: 5))
        app.buttons["agent.edit.General Assistant"].click(); app.tabs["Skills"].click()
        XCTAssertTrue(selection.waitForExistence(timeout: 5)); XCTAssertEqual((selection.value as? NSNumber)?.intValue, 1)
    }

    @MainActor
    func testSharedInstructionsSaveAndAppearInAgentPreview() {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
        app.launchArguments += ["-ApplePersistenceIgnoreState", "YES"]
        app.launch()
        XCTAssertTrue(app.buttons["workspace.create.empty"].waitForExistence(timeout: 5))
        app.buttons["workspace.create.empty"].click(); saveName("Personal", in: app)
        XCTAssertTrue(app.buttons["project.create.empty"].waitForExistence(timeout: 5))
        app.buttons["project.create.empty"].click(); saveName("Instruction Project", in: app)
        XCTAssertTrue(app.buttons["project.agents.Instruction Project"].waitForExistence(timeout: 5))
        app.buttons["project.agents.Instruction Project"].click()
        XCTAssertTrue(app.buttons["agent.create"].waitForExistence(timeout: 5))
        app.buttons["agent.create"].click()
        XCTAssertTrue(app.buttons["agent.save"].waitForExistence(timeout: 5))
        app.buttons["agent.save"].click()
        XCTAssertTrue(app.buttons["agent.preview.General Assistant"].waitForExistence(timeout: 5))
        app.buttons["instructions.shared"].click()
        XCTAssertTrue(app.buttons["instructions.add"].waitForExistence(timeout: 5))
        app.buttons["instructions.add"].click()
        let title = app.textFields["instructions.title"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.click(); title.typeKey("a", modifierFlags: .command); title.typeText("Synthetic Guidance")
        let text = app.textViews["instructions.text"]
        text.click(); text.typeKey("a", modifierFlags: .command); text.typeText("Record exact synthetic evidence before interpreting it.")
        app.buttons["instructions.save"].click()
        XCTAssertTrue(app.buttons["agent.preview.General Assistant"].waitForExistence(timeout: 5))
        app.buttons["agent.preview.General Assistant"].click()
        XCTAssertTrue(app.staticTexts["instruction.source.Project"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Synthetic Guidance"].exists)
        XCTAssertTrue(app.staticTexts["Record exact synthetic evidence before interpreting it."].exists)
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "Effective instructions with exact sources"; attachment.lifetime = .keepAlways; add(attachment)
        app.buttons["instructions.preview.done"].click()
        app.terminate(); app.launch()
        XCTAssertTrue(app.buttons["project.agents.Instruction Project"].waitForExistence(timeout: 5))
        app.buttons["project.agents.Instruction Project"].click()
        XCTAssertTrue(app.buttons["instructions.shared"].waitForExistence(timeout: 5))
        app.buttons["instructions.shared"].click()
        XCTAssertTrue(app.textViews["instructions.text"].waitForExistence(timeout: 5))
        XCTAssertEqual(app.textViews["instructions.text"].value as? String, "Record exact synthetic evidence before interpreting it.")
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
        XCTAssertTrue(app.staticTexts["runs.sessions.empty"].waitForExistence(timeout: 5))
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
