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
    func testCredentialPolicyControlsSecretReadsAndProcessStartup() async throws {
        for (disposition, review): (PolicyDisposition, Bool) in [(.allow, false), (.deny, false), (.approval, false), (.approval, true)] {
        let script = """
        import json, sys, os
        assert os.environ.get("SYNTHETIC_TOKEN") == "fixture-value"
        for line in sys.stdin:
            r = json.loads(line)
            if 'id' not in r: continue
            result = {'resultType':'complete'}
            if r['method'] == 'server/discover':
                result.update({'supportedVersions':['2026-07-28'],'capabilities':{'tools':{}},'_meta':{'io.modelcontextprotocol/serverInfo':{'name':os.environ['SYNTHETIC_TOKEN'],'version':'1'}}})
            elif r['method'] == 'resources/read':
                value = os.environ['SYNTHETIC_TOKEN']
                assert r['params']['uri'] == 'urn:'+value
                result.update({'ttlMs':0,'cacheScope':'private','contents':[{'uri':'urn:'+value,'mimeType':value,'text':value},{'uri':'urn:binary','blob':'AP9B'}]})
            elif r['method'] == 'resources/list':
                value = os.environ['SYNTHETIC_TOKEN']
                result.update({'ttlMs':0,'cacheScope':'private','resources':[{'uri':'urn:'+value,'name':value,'title':value,'description':value,'mimeType':value,'size':42}]})
            elif r['method'] == 'prompts/list':
                value = os.environ['SYNTHETIC_TOKEN']
                result.update({'ttlMs':0,'cacheScope':'private','prompts':[{'name':value,'title':value,'description':value,'arguments':[{'name':value,'title':value,'description':value,'required':True}]}]})
            elif r['method'] == 'tools/list':
                value = os.environ['SYNTHETIC_TOKEN']
                result.update({'ttlMs':0,'cacheScope':'private','tools':[{'name':value,'title':value,'description':value,'inputSchema':{'type':'object'},'annotations':{'readOnlyHint':True}}]})
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
        let secretScope = try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment)
        let reference = SecretReference(scope: secretScope)
        let secrets = MCPFixtureSecrets(scope: secretScope)
        let config = try MCPStdioConfiguration(id: id, scope: scope, environmentID: environment, name: "Synthetic", executable: "/usr/bin/python3", arguments: ["-u", "-c", script], workingDirectory: path, secretEnvironment: ["SYNTHETIC_TOKEN": reference], enabled: true)
        _ = try await configurations.save(config, in: scope, expectedRevision: nil)
        let rules = PolicyOperation.allCases.map { PolicyRule($0, $0 == .readSecret ? disposition : ($0 == .readEvidence && review ? .approval : .allow)) }
        let policy = try PolicySnapshot(
            workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
            project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
            environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment],
            operations: [.runShell, .readSecret, .readEvidence], canApprove: true, expiresAt: Date().addingTimeInterval(600))
        let approvals = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
        let directory = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let launch = try await MCPApprovedStdioLaunch.open(configurations: configurations, connectionID: id,
            scope: scope, environmentID: environment, workspaceRoot: root, projectRoot: directory,
            authorities: [user], requesterID: user.id, approvals: approvals, secrets: secrets, currentPolicy: { policy })
        do { _ = try await launch.start(approvalID: UUID()); XCTFail("Unreviewed launch succeeded") }
        catch { XCTAssertTrue(error is AuthorizationError) }
        guard case .approval(let pending) = try await launch.prepare() else { return XCTFail("Missing approval") }
        _ = try await launch.review(pending.id, approve: true, expectedSequence: pending.sequence)
        var credentialApprovalID: UUID?
        if review {
            do {
                _ = try await launch.reviewCredentials(pending.id, approve: true, expectedSequence: pending.sequence)
                XCTFail("Launch approval accepted as credential approval")
            } catch { XCTAssertTrue(error is AuthorizationError) }
            guard case .approval(let credentials) = try await launch.prepareCredentials() else { return XCTFail("Missing credential approval") }
            _ = try await launch.reviewCredentials(credentials.id, approve: true, expectedSequence: credentials.sequence)
            credentialApprovalID = credentials.id
        }
        do {
            let server = try await launch.start(approvalID: pending.id, credentialApprovalID: credentialApprovalID)
            XCTAssertTrue(disposition == .allow || review)
            XCTAssertEqual(server.mode, .modern)
            let name = try XCTUnwrap(server.name)
            XCTAssertFalse(name.text.contains("fixture-value"))
            XCTAssertGreaterThan(name.redactionCount, 0)
            XCTAssertEqual(name.context.scope, scope)
            var discoveryApproval: UUID?
            if review {
                do { _ = try await launch.discoverTools(); XCTFail("Discovery skipped approval") }
                catch { XCTAssertEqual(error as? AuthorizationError, .approvalRequired) }
                guard case .approval(let discovery) = try await launch.prepareDiscovery() else { return XCTFail("Missing discovery review") }
                _ = try await launch.reviewDiscovery(discovery.id, approve: true, expectedSequence: discovery.sequence)
                discoveryApproval = discovery.id
            }
            var promptApproval: UUID?
            if review {
                do { _ = try await launch.discoverPrompts(approvalID: discoveryApproval); XCTFail("Tool approval authorized prompt discovery") }
                catch { XCTAssertTrue(error is AuthorizationError) }
                guard case .approval(let prompt) = try await launch.preparePromptDiscovery() else { return XCTFail("Missing prompt review") }
                _ = try await launch.reviewPromptDiscovery(prompt.id, approve: true, expectedSequence: prompt.sequence)
                promptApproval = prompt.id
            }
            var resourceApproval: UUID?
            if review {
                for other in [discoveryApproval, promptApproval].compactMap({ $0 }) {
                    do { _ = try await launch.discoverResources(approvalID: other); XCTFail("Other discovery approval authorized resources") }
                    catch { XCTAssertTrue(error is AuthorizationError) }
                }
                guard case .approval(let resource) = try await launch.prepareResourceDiscovery() else { return XCTFail("Missing resource review") }
                _ = try await launch.reviewResourceDiscovery(resource.id, approve: true, expectedSequence: resource.sequence)
                resourceApproval = resource.id
            }
            let resourceCatalog = try await launch.discoverResources(approvalID: resourceApproval)
            XCTAssertEqual(resourceCatalog.scope, scope); XCTAssertEqual(resourceCatalog.environmentID, environment)
            XCTAssertEqual(resourceCatalog.connectionID, id); XCTAssertEqual(resourceCatalog.resources.count, 1)
            let resource = try XCTUnwrap(resourceCatalog.resources.first)
            for field in [resource.uri, resource.name, try XCTUnwrap(resource.title),
                          try XCTUnwrap(resource.description), try XCTUnwrap(resource.mimeType)] {
                XCTAssertFalse(field.text.contains("fixture-value")); XCTAssertGreaterThan(field.redactionCount, 0)
                XCTAssertEqual(field.context.scope, scope); XCTAssertEqual(field.context.environmentID, environment)
            }
            XCTAssertEqual(resource.sizeBytes?.text, "42")
            XCTAssertEqual(resource.sizeBytes?.context.scope, scope)
            do { _ = try await launch.readResource(resourceID: UUID()); XCTFail("Unknown resource handle read") }
            catch { XCTAssertEqual(error as? AuthorizationError, .invalidInput) }
            var readApproval: UUID?
            if review {
                do { _ = try await launch.readResource(resourceID: resource.id); XCTFail("Read skipped approval") }
                catch { XCTAssertEqual(error as? AuthorizationError, .approvalRequired) }
                do { _ = try await launch.readResource(resourceID: resource.id, approvalID: resourceApproval); XCTFail("Listing approval authorized read") }
                catch { XCTAssertEqual(error as? AuthorizationError, .invalidApproval) }
                guard case .approval(let read) = try await launch.prepareResourceRead(resourceID: resource.id) else { return XCTFail("Missing read review") }
                _ = try await launch.reviewResourceRead(read.id, resourceID: resource.id, approve: true, expectedSequence: read.sequence)
                readApproval = read.id
            }
            let content = try await launch.readResource(resourceID: resource.id, approvalID: readApproval)
            XCTAssertEqual(content.scope, scope); XCTAssertEqual(content.environmentID, environment)
            XCTAssertEqual(content.connectionID, id); XCTAssertEqual(content.resourceID, resource.id)
            XCTAssertEqual(content.contents.count, 2)
            let first = try XCTUnwrap(content.contents.first)
            guard case .text(let text) = first.body else { return XCTFail("Missing text body") }
            for field in [first.uri, try XCTUnwrap(first.mimeType), text] {
                XCTAssertFalse(field.text.contains("fixture-value")); XCTAssertGreaterThan(field.redactionCount, 0)
                XCTAssertEqual(field.context.scope, scope); XCTAssertEqual(field.context.environmentID, environment)
            }
            guard case .binary(let size) = content.contents[1].body else { return XCTFail("Binary exposed as text") }
            XCTAssertEqual(size.text, "3"); XCTAssertEqual(size.context.scope, scope)
            if !review {
                _ = try await launch.discoverResources()
                do { _ = try await launch.readResource(resourceID: resource.id); XCTFail("Refreshed handle remained valid") }
                catch { XCTAssertEqual(error as? AuthorizationError, .invalidInput) }
            }
            let promptCatalog = try await launch.discoverPrompts(approvalID: promptApproval)
            XCTAssertEqual(promptCatalog.scope, scope); XCTAssertEqual(promptCatalog.environmentID, environment)
            XCTAssertEqual(promptCatalog.connectionID, id); XCTAssertEqual(promptCatalog.prompts.count, 1)
            let prompt = try XCTUnwrap(promptCatalog.prompts.first)
            let argument = try XCTUnwrap(prompt.arguments?.first)
            XCTAssertEqual(argument.required, true)
            for field in [prompt.name, try XCTUnwrap(prompt.title), try XCTUnwrap(prompt.description),
                          argument.name, try XCTUnwrap(argument.title), try XCTUnwrap(argument.description)] {
                XCTAssertFalse(field.text.contains("fixture-value")); XCTAssertGreaterThan(field.redactionCount, 0)
                XCTAssertEqual(field.context.scope, scope); XCTAssertEqual(field.context.environmentID, environment)
            }
            let tools = try await launch.discoverTools(approvalID: discoveryApproval)
            XCTAssertEqual(tools.scope, scope)
            XCTAssertEqual(tools.environmentID, environment)
            XCTAssertEqual(tools.connectionID, id)
            let tool = try XCTUnwrap(tools.tools.first)
            XCTAssertEqual(tools.tools.count, 1)
            for field in [tool.name, try XCTUnwrap(tool.title), try XCTUnwrap(tool.description)] {
                XCTAssertFalse(field.text.contains("fixture-value"))
                XCTAssertGreaterThan(field.redactionCount, 0)
                XCTAssertEqual(field.context.scope, scope)
                XCTAssertEqual(field.context.environmentID, environment)
            }
            XCTAssertEqual(tool.readOnlyHint, true)
            XCTAssertNil(tool.destructiveHint)
            try await launch.ping()
        } catch {
            XCTAssertFalse(disposition == .allow || review, "Authorized integration failed: \(error)")
            XCTAssertEqual(error as? AuthorizationError, disposition == .deny ? .denied : .approvalRequired)
        }
        let reads = await secrets.reads
        XCTAssertEqual(reads, (disposition == .allow || review) ? 1 : 0)
        await launch.close()
        do { _ = try await launch.readResource(resourceID: UUID()); XCTFail("Closed resource read succeeded") }
        catch { XCTAssertEqual(error as? MCPProcessError, .closed) }
        do { _ = try await launch.discoverResources(); XCTFail("Closed resource discovery succeeded") }
        catch { XCTAssertEqual(error as? MCPProcessError, .closed) }
        do { _ = try await launch.discoverPrompts(); XCTFail("Closed prompt discovery succeeded") }
        catch { XCTAssertEqual(error as? MCPProcessError, .closed) }
        do { _ = try await launch.discoverTools(); XCTFail("Closed discovery succeeded") }
        catch { XCTAssertEqual(error as? MCPProcessError, .closed) }
        do { try await launch.ping(); XCTFail("Closed connection remained usable") }
        catch { XCTAssertEqual(error as? MCPProcessError, .closed) }
        }
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
        do { _ = try await launch.discoverResources(); XCTFail("Launch-only authority listed resources") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        do { _ = try await launch.discoverPrompts(); XCTFail("Launch-only authority listed prompts") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        do { _ = try await launch.discoverTools(); XCTFail("Launch-only authority listed tools") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        do { _ = try await launch.start(approvalID: pending.id); XCTFail("Repeated start succeeded") }
        catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        await launch.close()
        do { try await launch.ping(); XCTFail("Closed connection remained usable") }
        catch { XCTAssertEqual(error as? MCPProcessError, .closed) }
    }
}
private actor MCPFixtureSecrets: SecretStore {
    nonisolated let scope: SecretScope
    private(set) var reads = 0
    init(scope: SecretScope) { self.scope = scope }
    func get(_ reference: SecretReference) throws -> SecretValue? {
        guard reference.scope == scope else { throw SecretStoreError.scopeMismatch }
        reads += 1
        return try SecretValue(Data("fixture-value".utf8))
    }
    func set(_ value: SecretValue, for reference: SecretReference) throws { throw SecretStoreError.invalidValue }
    func delete(_ reference: SecretReference) throws { throw SecretStoreError.invalidValue }
    func exists(_ reference: SecretReference) -> Bool { reference.scope == scope }
}
#endif
