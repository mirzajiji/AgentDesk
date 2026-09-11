import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraIssueEditDraftTests: XCTestCase {
    func testFieldsAreExplicitAndApprovalBindsObservedState() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID(), run = RunID()
        let context = RedactionContext(scope: scope, environmentID: environment, runID: run)
        let redactor = try ContentRedactor(context: context)
        let before = try ActionFingerprint.canonical("observed-state")
        let summary = try redactor.redactText("Reviewed summary", in: context)
        let first = try JiraIssueEditDraft(identifier: "SYN-1", summary: summary, expectedIssue: before)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: first.body) as? [String: Any])
        let fields = try XCTUnwrap(object["fields"] as? [String: Any])
        XCTAssertEqual(fields["summary"] as? String, "Reviewed summary")
        XCTAssertNil(fields["description"], "Omission must not clear another field")
        let cleared = try JiraIssueEditDraft(identifier: "SYN-1", description: redactor.redactText("", in: context), expectedIssue: before)
        let clearingObject = try XCTUnwrap(JSONSerialization.jsonObject(with: cleared.body) as? [String: Any])
        let clearingFields = try XCTUnwrap(clearingObject["fields"] as? [String: Any])
        XCTAssertNil(clearingFields["summary"])
        XCTAssertNotNil(clearingFields["description"])
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment, instance: URL(string: "https://synthetic.atlassian.net")!, enabled: true)
        let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(.issuesUpdate, .approval)])
        let id = UUID(), cloud = UUID()
        func prepare(_ draft: JiraIssueEditDraft) throws -> PreparedPluginAction {
            try draft.prepare(id: id, configuration: config, configurationRevision: 1, permissions: permissions, cloudID: cloud, runID: run)
        }
        let changed = try JiraIssueEditDraft(identifier: "SYN-1", summary: summary, expectedIssue: .canonical("changed-state"))
        XCTAssertNotEqual(try prepare(first).action, try prepare(changed).action)
        XCTAssertNotEqual(try prepare(first).action, try prepare(cleared).action)
        XCTAssertThrowsError(try JiraIssueEditDraft(identifier: "SYN-1", expectedIssue: before))
        for text in ["", "line\nbreak", String(repeating: "x", count: 256)] {
            XCTAssertThrowsError(try JiraIssueEditDraft(identifier: "SYN-1", summary: redactor.redactText(text, in: context), expectedIssue: before))
        }
        let foreign = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        XCTAssertThrowsError(try JiraIssueEditDraft(identifier: "SYN-1", summary: summary,
            description: ContentRedactor(context: foreign).redactText("Other run", in: foreign), expectedIssue: before))
    }
}
