#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskSecurity
import Foundation
import XCTest
@testable import AgentDeskRuntime
@testable import AgentDesk

/// Signed native host, real Keychain, real scoped configuration and real stdio process.
@MainActor final class NativeMCPCredentialIntegrationTests: XCTestCase {
    func testSavedCredentialRequiresReviewBeforeReachingNativeServer() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let workspaces = root.appendingPathComponent("Workspaces"), repository = root.appendingPathComponent("SyntheticRepository")
        for url in [root, workspaces, repository] {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: workspaces)
        let workspace = try await catalog.createWorkspace(name: "Synthetic MCP Keychain")
        let project = try await catalog.createProject(in: workspace.id, name: "Synthetic native project")
        let environmentID = EnvironmentID(), rules = [PolicyRule(.runShell, .approval), PolicyRule(.readSecret, .approval)]
        let setup = ProjectExecutionSetupService(catalog: catalog, scope: project.scope)
        _ = try await setup.save(.init(policy: PolicyDocument(level: .workspace, workspaceID: workspace.id, rules: rules)), at: .workspace, expectedRevision: nil)
        let environment = ProjectEnvironment(id: environmentID, scope: project.scope, name: "Synthetic", kind: .test,
            policy: try PolicyDocument(level: .environment, workspaceID: workspace.id, projectID: project.id, environmentID: environmentID, rules: rules))
        _ = try await setup.save(.init(environments: [environment], defaultEnvironmentID: environmentID,
            policy: PolicyDocument(level: .project, workspaceID: workspace.id, projectID: project.id, rules: rules)), at: .project, expectedRevision: nil)
        let initialized = try await MacCommandCapture.run(executable: GitExecutableLocator.installed(), arguments: ["init", "--initial-branch=main"],
            directory: repository, environment: GitCaptureConfiguration.environment, timeout: .seconds(10), maximumBytes: 65_536)
        XCTAssertEqual(initialized.status, 0)
        let browser = WorkspaceBrowserModel(catalog: catalog, applicationRoot: root)
        let services = try await browser.executionServices(for: project)
        _ = try await services.repositories.register(repository, in: project.scope, expectedRevision: nil)
        let python = "/Applications/Xcode.app/Contents/Developer/usr/bin/python3"
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: python))
        let script = """
        import json, os, sys
        assert os.environ.get('NATIVE_TOKEN')
        for line in sys.stdin:
            r = json.loads(line)
            if 'id' not in r: continue
            result = {'resultType':'complete'}
            if r['method'] == 'server/discover':
                result.update({'supportedVersions':['2026-07-28'],'capabilities':{},'_meta':{'io.modelcontextprotocol/serverInfo':{'name':os.environ['NATIVE_TOKEN'],'version':'1'}}})
            print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}), flush=True)
        """
        let store = try await catalog.mcpConfigurationStore(for: MCPStdioConfiguration.self, in: project.scope)
        let initial = try await store.save(MCPStdioConfiguration(scope: project.scope, environmentID: environmentID,
            name: "Synthetic Keychain server", executable: python, arguments: ["-u", "-c", script], workingDirectory: nil,
            enabled: true, directoryBase: .registeredRepository), in: project.scope, expectedRevision: nil)
        let keychain = KeychainSecretStore(scope: try SecretScope(workspaceID: workspace.id, projectID: project.id, environmentID: environmentID))
        var reference: SecretReference?
        var lifecycle: NativeMCPLifecycleModel?
        do {
            let editor = NativeMCPCredentialModel { variable, value in
                try await browser.saveMCPCredential(project: project, record: initial, variable: variable, value: value)
            }
            editor.variable = "NATIVE_TOKEN"; editor.value = "synthetic-native-keychain-value"; editor.save()
            for _ in 0..<200 where editor.busy { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertTrue(editor.saved, editor.error ?? "Native credential save did not finish")
            XCTAssertEqual(editor.value, "")
            let saved = try await store.read(id: initial.configuration.id, in: project.scope)
            let record = try XCTUnwrap(saved)
            reference = try XCTUnwrap(record.configuration.secretEnvironment["NATIVE_TOKEN"])
            let stored = try await keychain.get(XCTUnwrap(reference))
            XCTAssertEqual(stored?.withBytes { $0 }, Data("synthetic-native-keychain-value".utf8))
            XCTAssertEqual(record.revision, 2)
            let encoded = try JSONEncoder().encode(record)
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains("synthetic-native-keychain-value"))
            let model = NativeMCPLifecycleModel(needsCredentials: true) { try await browser.openMCP(project: project, record: record) }
            lifecycle = model; model.prepare(); try await settle(model)
            XCTAssertNotNil(model.pending); XCTAssertFalse(model.connected)
            model.approve(); try await settle(model)
            XCTAssertTrue(model.reviewingCredentials); XCTAssertNotNil(model.pending); XCTAssertFalse(model.connected)
            model.approve(); try await settle(model)
            XCTAssertTrue(model.connected, model.message)
            XCTAssertFalse(model.message.contains("synthetic-native-keychain-value"))
            model.checkHealth(); try await settle(model)
            XCTAssertEqual(model.message, "Server responded to the health check.")
            model.stop(); try await settle(model)
            try await keychain.delete(XCTUnwrap(reference))
            let remains = try await keychain.exists(XCTUnwrap(reference)); XCTAssertFalse(remains)
        } catch {
            if let lifecycle { lifecycle.stop(); try? await settle(lifecycle) }
            if reference == nil { reference = try? await store.read(id: initial.configuration.id, in: project.scope)?.configuration.secretEnvironment["NATIVE_TOKEN"] }
            if let reference { try? await keychain.delete(reference) }
            throw error
        }
    }
    private func settle(_ model: NativeMCPLifecycleModel) async throws {
        for _ in 0..<1500 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.busy)
    }
}
#endif
