import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraCommentDraftTests: XCTestCase {
    func testDraftPreservesTextAndBindsExactContentTargetCloudAndScope() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID(), run = RunID()
        let context = RedactionContext(scope: scope, environmentID: environment, runID: run)
        let redactor = try ContentRedactor(context: context)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment, instance: URL(string: "https://synthetic.atlassian.net")!, enabled: true)
        let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(.commentsWrite, .approval)])
        let id = UUID(), cloud = UUID()
        func draft(_ text: String, identifier: String = "A-1") throws -> JiraCommentDraft {
            try JiraCommentDraft(identifier: identifier, content: redactor.redactText(text, in: context))
        }
        func prepare(_ draft: JiraCommentDraft, cloudID: UUID? = nil, runID: RunID? = nil) throws -> PreparedPluginAction {
            try draft.prepare(id: id, configuration: config, configurationRevision: 1, permissions: permissions, cloudID: cloudID ?? cloud, runID: runID ?? run)
        }
        let original = try draft("Observed first line\n\nSecond line")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: original.body) as? [String: Any])
        let body = try XCTUnwrap(json["body"] as? [String: Any])
        XCTAssertEqual(body["type"] as? String, "doc")
        XCTAssertEqual(body["version"] as? Int, 1)
        let paragraphs = try XCTUnwrap(body["content"] as? [[String: Any]])
        XCTAssertEqual(paragraphs.count, 3)
        XCTAssertEqual((paragraphs[1]["content"] as? [Any])?.count, 0)
        let prepared = try prepare(original)
        XCTAssertEqual(prepared.capability, .commentsWrite)
        XCTAssertEqual(prepared.action, try prepare(original).action)
        XCTAssertNotEqual(prepared.action, try prepare(draft("Changed evidence")).action)
        XCTAssertNotEqual(prepared.action, try prepare(draft(original.content.text, identifier: "A-2")).action)
        XCTAssertNotEqual(prepared.action, try prepare(original, cloudID: UUID()).action)
        XCTAssertThrowsError(try prepare(original, runID: RunID()))
        XCTAssertThrowsError(try draft(" \n "))
        XCTAssertThrowsError(try draft("body", identifier: "../foreign"))
        XCTAssertThrowsError(try draft(String(repeating: "x", count: 32_769)))
    }
}
