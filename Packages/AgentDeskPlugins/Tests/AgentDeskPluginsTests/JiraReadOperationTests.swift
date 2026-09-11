import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class JiraReadOperationTests: XCTestCase {
    func testPreparedIdentityBindsExactPageContentLimitAndCloud() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment, instance: URL(string: "https://synthetic.atlassian.net")!, enabled: true)
        let permissions = try PluginPermissions(connectionID: config.id, scope: scope, environmentID: environment, rules: [.init(.commentsRead, .approval)])
        let invocationID = UUID(), cloudID = UUID(), runID = RunID()
        func prepare(_ operation: JiraReadOperation, cloud: UUID? = nil) throws -> PreparedPluginAction {
            try operation.prepare(id: invocationID, configuration: config, configurationRevision: 1, permissions: permissions, cloudID: cloud ?? cloudID, runID: runID)
        }
        let first = try prepare(.comments(identifier: "A-1", startAt: 0, limit: 20))
        XCTAssertEqual(first.capability, .commentsRead)
        XCTAssertEqual(first.action, try prepare(.comments(identifier: "A-1", startAt: 0, limit: 20)).action)
        for changed in [JiraReadOperation.comments(identifier: "A-1", startAt: 20, limit: 20), .comments(identifier: "A-1", startAt: 0, limit: 40), .comments(identifier: "A-2", startAt: 0, limit: 20), .issue(identifier: "A-1")] {
            XCTAssertNotEqual(first.action, try prepare(changed).action)
        }
        XCTAssertNotEqual(first.action, try prepare(.comments(identifier: "A-1", startAt: 0, limit: 20), cloud: UUID()).action)
        let metadata = try prepare(.attachmentMetadata(id: "123"))
        let bytes = try prepare(.attachmentContent(id: "123", expectedSize: 4, maximumBytes: 8))
        XCTAssertNotEqual(metadata.action, bytes.action)
        XCTAssertNotEqual(bytes.action, try prepare(.attachmentContent(id: "123", expectedSize: 5, maximumBytes: 8)).action)
        XCTAssertNotEqual(bytes.action, try prepare(.attachmentContent(id: "123", expectedSize: 4, maximumBytes: 16)).action)
        for invalid in [JiraReadOperation.issue(identifier: "../1"), .comments(identifier: "A-1", startAt: -1, limit: 1), .attachmentMetadata(id: "x"), .attachmentContent(id: "123", expectedSize: 9, maximumBytes: 8)] {
            XCTAssertThrowsError(try prepare(invalid))
        }
    }
}
