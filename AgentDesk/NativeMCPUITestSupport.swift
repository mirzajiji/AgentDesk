#if DEBUG && os(macOS)
import AgentDeskCore
import AgentDeskMCP
import Foundation
@testable import AgentDeskRuntime

/// Exercises the production MCP path using an app-owned synthetic repository and stdio process.
enum NativeMCPUITestSupport {
    static func seed(catalog: WorkspaceCatalog, project: ProjectRecord, applicationRoot: URL) async throws {
        guard ProcessInfo.processInfo.environment["AGENTDESK_TEST_MCP_LIFECYCLE"] == "stdio",
              NativeRunUITestSupport.mode() != nil else { return }
        guard applicationRoot.standardizedFileURL == (try NativeRunUITestSupport.root()).standardizedFileURL else {
            throw CatalogError.invalidConfiguration
        }
        let setup = ProjectExecutionSetupService(catalog: catalog, scope: project.scope)
        let settings = try await setup.settings()
        guard let current = settings.project, let workspace = settings.workspace,
              let environmentID = current.draft.environments.first?.id else { throw CatalogError.invalidConfiguration }
        let rules = [PolicyRule(.runShell, .approval)]
        let environment = ProjectEnvironment(id: environmentID, scope: project.scope, name: "Synthetic MCP", kind: .test,
            policy: try PolicyDocument(level: .environment, workspaceID: project.workspaceID, projectID: project.id,
                environmentID: environmentID, rules: rules))
        _ = try await setup.save(.init(policy: PolicyDocument(level: .workspace, workspaceID: project.workspaceID, rules: rules)),
            at: .workspace, expectedRevision: workspace.revision)
        _ = try await setup.save(.init(environments: [environment], defaultEnvironmentID: environmentID,
            policy: PolicyDocument(level: .project, workspaceID: project.workspaceID, projectID: project.id, rules: rules)),
            at: .project, expectedRevision: current.revision)
        let repository = applicationRoot.appendingPathComponent("SyntheticMCPRepository")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        let initialized = try await MacCommandCapture.run(executable: GitExecutableLocator.installed(),
            arguments: ["init", "--initial-branch=main"], directory: repository, environment: GitCaptureConfiguration.environment,
            timeout: .seconds(10), maximumBytes: 65_536)
        guard initialized.status == 0 else { throw CatalogError.invalidConfiguration }
        let directories = try NativeProjectStorage.prepare(root: applicationRoot, workspaceID: project.workspaceID)
        let registry = try ProjectRepositoryRegistry(catalog: catalog, container: directories.access)
        _ = try await registry.register(repository, in: project.scope, expectedRevision: nil)
        guard let python = ProcessInfo.processInfo.environment["AGENTDESK_TEST_MCP_PYTHON"],
              python.hasPrefix("/"), FileManager.default.isExecutableFile(atPath: python) else { throw CatalogError.invalidConfiguration }
        let script = """
        import json, sys
        for line in sys.stdin:
            r = json.loads(line)
            if 'id' not in r: continue
            result = {'resultType':'complete'}
            if r['method'] == 'server/discover':
                result.update({'supportedVersions':['2026-07-28'],'capabilities':{},'_meta':{'io.modelcontextprotocol/serverInfo':{'name':'Synthetic native server','version':'1'}}})
            print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}), flush=True)
        """
        let store = try await catalog.mcpConfigurationStore(for: MCPStdioConfiguration.self, in: project.scope)
        _ = try await store.save(MCPStdioConfiguration(scope: project.scope, environmentID: environmentID,
            name: "Synthetic native MCP", executable: python, arguments: ["-u", "-c", script],
            workingDirectory: nil, enabled: true, directoryBase: .registeredRepository), in: project.scope, expectedRevision: nil)
    }
}
#endif
