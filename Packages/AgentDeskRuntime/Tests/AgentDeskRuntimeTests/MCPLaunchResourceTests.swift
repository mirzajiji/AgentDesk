#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import Foundation
import Darwin
import XCTest
@testable import AgentDeskRuntime

final class MCPLaunchResourceTests: XCTestCase {
    func testRegisteredRepositoryRootOutsideWorkspace() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspace = root.appendingPathComponent("workspace")
        let repository = root.appendingPathComponent("external-repository")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let config = try MCPStdioConfiguration(scope: scope, environmentID: EnvironmentID(), name: "Synthetic",
            executable: "/usr/bin/true", workingDirectory: nil, directoryBase: .registeredRepository)
        let resolved = try MCPLaunchResource.resolve(config, scope: scope, workspaceRoot: workspace, projectRoot: repository)
        let canonical = try XCTUnwrap(realpath(repository.path, nil))
        defer { free(canonical) }
        XCTAssertEqual(resolved.directory.path, String(cString: canonical))
        XCTAssertThrowsError(try MCPStdioConfiguration(scope: scope, environmentID: EnvironmentID(), name: "Synthetic",
            executable: "/usr/bin/true", workingDirectory: nil))
        try FileManager.default.createSymbolicLink(at: repository.appendingPathComponent("escape"), withDestinationURL: workspace)
        let escaped = try MCPStdioConfiguration(scope: scope, environmentID: EnvironmentID(), name: "Synthetic", executable: "/usr/bin/true",
            workingDirectory: WorkspacePath(workspaceID: scope.workspaceID, relativePath: "escape"), directoryBase: .registeredRepository)
        XCTAssertThrowsError(try MCPLaunchResource.resolve(escaped, scope: scope, workspaceRoot: workspace, projectRoot: repository))
    }
    func testExecutableChangesInvalidateIdentityAndNonExecutableFilesFail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = project.appendingPathComponent("server")
        try Data("synthetic".utf8).write(to: executable)
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let configuration = try MCPStdioConfiguration(scope: scope, environmentID: EnvironmentID(), name: "Synthetic",
            executable: executable.path, workingDirectory: WorkspacePath(workspaceID: scope.workspaceID, relativePath: "project"))
        XCTAssertThrowsError(try MCPLaunchResource.resolve(configuration, scope: scope, workspaceRoot: root, projectRoot: project))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let before = try MCPLaunchResource.resolve(configuration, scope: scope, workspaceRoot: root, projectRoot: project)
        try Data("changed synthetic executable".utf8).write(to: executable)
        let after = try MCPLaunchResource.resolve(configuration, scope: scope, workspaceRoot: root, projectRoot: project)
        XCTAssertNotEqual(before.fingerprint, after.fingerprint)
    }
    func testProjectContainmentAndSymlinkEscapes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let project = root.appendingPathComponent("project")
        let sibling = root.appendingPathComponent("project-other")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sibling, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: project.appendingPathComponent("escape"), withDestinationURL: sibling)
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        func configuration(_ path: String) throws -> MCPStdioConfiguration {
            try MCPStdioConfiguration(scope: scope, environmentID: EnvironmentID(), name: "Synthetic", executable: "/usr/bin/true",
                workingDirectory: WorkspacePath(workspaceID: scope.workspaceID, relativePath: path))
        }
        let good = try configuration("project")
        let first = try MCPLaunchResource.resolve(good, scope: scope, workspaceRoot: root, projectRoot: project)
        let again = try MCPLaunchResource.resolve(good, scope: scope, workspaceRoot: root, projectRoot: project)
        XCTAssertEqual(first.fingerprint, again.fingerprint)
        for path in ["project-other", "project/escape"] {
            XCTAssertThrowsError(try MCPLaunchResource.resolve(configuration(path), scope: scope, workspaceRoot: root, projectRoot: project)) {
                XCTAssertEqual($0 as? AuthorizationError, .scopeMismatch)
            }
        }
        XCTAssertThrowsError(try MCPLaunchResource.resolve(good, scope: .init(workspaceID: scope.workspaceID, projectID: ProjectID()), workspaceRoot: root, projectRoot: project))
    }
}
#endif
