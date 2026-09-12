#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor final class MCPApprovedLaunchTests: XCTestCase {
    func testCloseCancelsUnresponsiveStartup() async throws {
        let script = "import time; time.sleep(60)"
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "MCP policy")
        let scope = project.scope, environment = EnvironmentID(), id = UUID()
        let configurations = try await catalog.mcpConfigurationStore(for: MCPStdioConfiguration.self, in: scope)
        let path = try WorkspacePath(workspaceID: workspace.id, relativePath: "project")
        let config = try MCPStdioConfiguration(id: id, scope: scope, environmentID: environment, name: "Synthetic", executable: "/usr/bin/python3", arguments: ["-u", "-c", script], workingDirectory: path, enabled: true)
        _ = try await configurations.save(config, in: scope, expectedRevision: nil)
        let rules = PolicyOperation.allCases.map { PolicyRule($0, .allow) }
        let policy = try PolicySnapshot(
            workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
            project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
            environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment],
            operations: [.runShell], canApprove: true, expiresAt: Date().addingTimeInterval(600))
        let approvals = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let launch = try await MCPApprovedStdioLaunch.open(configurations: configurations, connectionID: id,
            scope: scope, environmentID: environment, workspaceRoot: root, projectRoot: directory,
            authorities: [user], requesterID: user.id, approvals: approvals, currentPolicy: { policy })
        guard case .approval(let pending) = try await launch.prepare() else { return XCTFail("Missing approval") }
        _ = try await launch.review(pending.id, approve: true, expectedSequence: pending.sequence)
        let startup = Task { try await launch.start(approvalID: pending.id) }
        try await Task.sleep(for: .milliseconds(100))
        let began = ContinuousClock.now
        await launch.close()
        XCTAssertLessThan(began.duration(to: .now), .seconds(2))
        do { _ = try await startup.value; XCTFail("Closed startup succeeded") }
        catch { XCTAssertTrue(error is CancellationError || error is AuthorizationError) }
    }
    func testReviewedProcessLaunchPingAndClose() async throws {
        let script = """
        import json, sys
        for line in sys.stdin:
            r = json.loads(line)
            if 'id' not in r: continue
            result = {'resultType':'complete'}
            if r['method'] == 'server/discover':
                result.update({'supportedVersions':['2026-07-28'],'capabilities':{}})
            print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}), flush=True)
        """
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "MCP policy")
        let scope = project.scope, environment = EnvironmentID(), id = UUID()
        let configurations = try await catalog.mcpConfigurationStore(for: MCPStdioConfiguration.self, in: scope)
        let path = try WorkspacePath(workspaceID: workspace.id, relativePath: "project")
        let config = try MCPStdioConfiguration(id: id, scope: scope, environmentID: environment, name: "Synthetic", executable: "/usr/bin/python3", arguments: ["-u", "-c", script], workingDirectory: path, enabled: true)
        _ = try await configurations.save(config, in: scope, expectedRevision: nil)
        let rules = PolicyOperation.allCases.map { PolicyRule($0, .allow) }
        let policy = try PolicySnapshot(
            workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
            project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
            environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment],
            operations: [.runShell], canApprove: true, expiresAt: Date().addingTimeInterval(600))
        let approvals = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let launch = try await MCPApprovedStdioLaunch.open(configurations: configurations, connectionID: id,
            scope: scope, environmentID: environment, workspaceRoot: root, projectRoot: directory,
            authorities: [user], requesterID: user.id, approvals: approvals, currentPolicy: { policy })
        do { _ = try await launch.start(approvalID: UUID()); XCTFail("Unreviewed launch succeeded") }
        catch { XCTAssertTrue(error is AuthorizationError) }
        guard case .approval(let pending) = try await launch.prepare() else { return XCTFail("Missing approval") }
        _ = try await launch.review(pending.id, approve: true, expectedSequence: pending.sequence)
        let server = try await launch.start(approvalID: pending.id)
        XCTAssertEqual(server.mode, .modern)
        try await launch.ping()
        do { _ = try await launch.start(approvalID: pending.id); XCTFail("Repeated start succeeded") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        await launch.close()
        do { try await launch.ping(); XCTFail("Closed connection remained usable") }
        catch { XCTAssertEqual(error as? MCPProcessError, .closed) }
    }
}
#endif
