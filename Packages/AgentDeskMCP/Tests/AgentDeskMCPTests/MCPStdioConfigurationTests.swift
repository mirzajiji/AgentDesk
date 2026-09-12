import AgentDeskCore
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskMCP

final class MCPStdioConfigurationTests: XCTestCase {
    func testRoundTripAndDecoderValidation() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let path = try WorkspacePath(workspaceID: scope.workspaceID, relativePath: "Projects/synthetic")
        let reference = SecretReference(scope: try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment))
        let value = try MCPStdioConfiguration(scope: scope, environmentID: environment, name: "Synthetic", executable: "/usr/bin/example", arguments: ["literal $(value)"], workingDirectory: path, secretEnvironment: ["TOKEN": reference])
        let data = try JSONEncoder().encode(value)
        XCTAssertEqual(try JSONDecoder().decode(MCPStdioConfiguration.self, from: data), value)
        XCTAssertFalse(value.enabled)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "directoryBase")
        let legacy = try JSONDecoder().decode(MCPStdioConfiguration.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(legacy.directoryBase, .workspace)
        let repository = try MCPStdioConfiguration(scope: scope, environmentID: environment, name: "Repository",
            executable: "/bin/example", workingDirectory: nil, directoryBase: .registeredRepository)
        XCTAssertEqual(try JSONDecoder().decode(MCPStdioConfiguration.self, from: JSONEncoder().encode(repository)), repository)
        object["executable"] = "../escape"
        XCTAssertThrowsError(try JSONDecoder().decode(MCPStdioConfiguration.self, from: JSONSerialization.data(withJSONObject: object)))
    }
    func testMalformedLaunchAndForeignScopeAreRejected() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let path = try WorkspacePath(workspaceID: scope.workspaceID, relativePath: "project")
        for executable in ["python", "/", "/a/../b", "/a//b", "/a\0b"] {
            XCTAssertThrowsError(try MCPStdioConfiguration(scope: scope, environmentID: environment, name: "Synthetic", executable: executable, workingDirectory: path))
        }
        let foreign = SecretReference(scope: try SecretScope(workspaceID: scope.workspaceID, projectID: ProjectID(), environmentID: environment))
        XCTAssertThrowsError(try MCPStdioConfiguration(scope: scope, environmentID: environment, name: "Synthetic", executable: "/bin/example", workingDirectory: path, secretEnvironment: ["TOKEN": foreign]))
        XCTAssertThrowsError(try MCPStdioConfiguration(scope: scope, environmentID: environment, name: "Synthetic", executable: "/bin/example", arguments: [String(repeating: "x", count: 8193)], workingDirectory: path))
    }
}
