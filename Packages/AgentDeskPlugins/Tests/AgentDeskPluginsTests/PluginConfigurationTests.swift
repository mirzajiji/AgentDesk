import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class PluginConfigurationTests: XCTestCase {
    func testRoundTripKeepsExactScopeAndCredentialReference() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let reference = SecretReference(scope: try SecretScope(workspaceID: scope.workspaceID,
            projectID: scope.projectID, environmentID: environment))
        let value = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: XCTUnwrap(URL(string: "https://jira.example.test/jira")), credential: reference)
        XCTAssertFalse(value.enabled)
        XCTAssertEqual(try JSONDecoder().decode(JiraConnectionConfiguration.self,
            from: JSONEncoder().encode(value)), value)
    }

    func testDecodedConfigurationCannotBypassValidation() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let reference = SecretReference(scope: try SecretScope(workspaceID: scope.workspaceID,
            projectID: scope.projectID, environmentID: environment))
        let value = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: XCTUnwrap(URL(string: "https://jira.example.test")), credential: reference)
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        var future = original; future["schemaVersion"] = 2
        XCTAssertThrowsError(try JSONDecoder().decode(JiraConnectionConfiguration.self,
            from: JSONSerialization.data(withJSONObject: future))) { error in
            XCTAssertEqual(error as? PluginConfigurationError, .unsupportedVersion)
        }
        var unsafe = original; unsafe["instance"] = "https://user:secret@jira.example.test"
        XCTAssertThrowsError(try JSONDecoder().decode(JiraConnectionConfiguration.self,
            from: JSONSerialization.data(withJSONObject: unsafe))) { error in
            XCTAssertEqual(error as? PluginConfigurationError, .invalidEndpoint)
        }
        var foreign = original
        foreign["environmentID"] = EnvironmentID().rawValue
        XCTAssertThrowsError(try JSONDecoder().decode(JiraConnectionConfiguration.self,
            from: JSONSerialization.data(withJSONObject: foreign))) { error in
            XCTAssertEqual(error as? PluginConfigurationError, .credentialScopeMismatch)
        }
    }

    func testRejectsEmbeddedCredentialsAndInsecureOrAmbiguousEndpoints() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        for endpoint in ["http://jira.example.test", "https://user:secret@jira.example.test",
                         "https://jira.example.test?token=secret", "https://jira.example.test#secret",
                         "https://jira.example.test:0", "file:///tmp/jira"] {
            XCTAssertThrowsError(try JiraConnectionConfiguration(scope: scope, environmentID: EnvironmentID(),
                instance: XCTUnwrap(URL(string: endpoint))))
        }
    }

    func testRejectsCredentialsFromOtherProjectsAndEnvironments() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        for secretScope in [
            try SecretScope(workspaceID: WorkspaceID(), projectID: scope.projectID, environmentID: environment),
            try SecretScope(workspaceID: scope.workspaceID, projectID: ProjectID(), environmentID: environment),
            try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: EnvironmentID()),
            try SecretScope(workspaceID: scope.workspaceID)
        ] {
            XCTAssertThrowsError(try JiraConnectionConfiguration(scope: scope, environmentID: environment,
                instance: XCTUnwrap(URL(string: "https://jira.example.test")),
                credential: SecretReference(scope: secretScope))) { error in
                XCTAssertEqual(error as? PluginConfigurationError, .credentialScopeMismatch)
            }
        }
    }
}
