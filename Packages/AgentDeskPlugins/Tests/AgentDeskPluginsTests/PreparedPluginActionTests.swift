import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class PreparedPluginActionTests: XCTestCase {
    func testBindingChangesForPayloadCapabilityConfigurationAndPermissions() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: EnvironmentID(),
            instance: XCTUnwrap(URL(string: "https://jira.example.test")), enabled: true)
        let permissions = try PluginPermissions(connectionID: config.id, scope: scope,
            environmentID: config.environmentID, rules: [.init(.issuesCreate, .approval), .init(.commentsWrite, .approval)])
        let resource = try ActionFingerprint(bytes: Data("SYN-1".utf8))
        let payload = try ActionFingerprint(bytes: Data("synthetic body".utf8))
        let id = UUID()
        func prepare(_ revision: Int = 1, _ capability: PluginCapability = .issuesCreate,
                     _ grants: PluginPermissions? = nil, _ body: ActionFingerprint? = nil) throws -> PolicyAction {
            try PreparedPluginAction(id: id, configuration: config, configurationRevision: revision,
                permissions: grants ?? permissions, capability: capability, resource: resource, payload: body ?? payload).action
        }
        let original = try prepare()
        XCTAssertEqual(original, try prepare())
        XCTAssertNotEqual(original.resource, try prepare(2).resource)
        XCTAssertNotEqual(original.resource, try prepare(1, .commentsWrite).resource)
        let changed = try PluginPermissions(revision: permissions.revision, connectionID: config.id, scope: scope,
            environmentID: config.environmentID, rules: [.init(.issuesCreate, .deny)])
        XCTAssertNotEqual(original.resource, try prepare(1, .issuesCreate, changed).resource)
        XCTAssertNotEqual(original.payload, try prepare(1, .issuesCreate, nil,
            ActionFingerprint(bytes: Data("changed".utf8))).payload)
        XCTAssertEqual(original.operation, .externalMutation)
        let moved = try JiraConnectionConfiguration(id: config.id, scope: scope, environmentID: config.environmentID,
            instance: XCTUnwrap(URL(string: "https://other.example.test")), enabled: true)
        let movedAction = try PreparedPluginAction(id: id, configuration: moved, configurationRevision: 1,
            permissions: permissions, capability: .issuesCreate, resource: resource, payload: payload)
        XCTAssertNotEqual(movedAction.action.resource, original.resource)
        let foreign = try PluginPermissions(connectionID: UUID(), scope: scope,
            environmentID: config.environmentID, rules: [.init(.issuesCreate, .allow)])
        XCTAssertThrowsError(try prepare(1, .issuesCreate, foreign)) { error in
            XCTAssertEqual(error as? AuthorizationError, .scopeMismatch)
        }
        XCTAssertThrowsError(try prepare(0))
    }
}
