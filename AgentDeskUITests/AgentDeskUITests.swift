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
    func testWorkspaceProjectCreationIsolationRenameAndReopen() {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
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
    func testWorkspaceValidationAndCancelPreserveSavedData() {
        let app = XCUIApplication()
        app.launchEnvironment["AGENTDESK_TEST_CONTAINER_ID"] = UUID().uuidString
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
        #endif
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        XCTAssertTrue(app.staticTexts["No Mac connected"].waitForExistence(timeout: 5))
    }
    #endif
}
