#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskSecurity
import AgentDeskPersistence
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskRuntime

private final class RegistryBookmarkFake: RepositoryBookmarkCoding, Sendable {
    struct State { var urls: [Data: URL] = [:]; var stale = false; var redirect: URL?; var active = 0 }
    let state = Mutex(State())
    func create(for url: URL) throws -> Data {
        let token = Data(UUID().uuidString.utf8)
        state.withLock { $0.urls[token] = url }; return token
    }
    func resolve(_ data: Data) throws -> (url: URL, stale: Bool) {
        try state.withLock {
            guard let url = $0.redirect ?? $0.urls[data] else { throw RepositoryRegistrationError.unavailable }
            return (url, $0.stale)
        }
    }
    func start(_ url: URL) -> Bool { state.withLock { $0.active += 1 }; return true }
    func stop(_ url: URL) { state.withLock { $0.active -= 1 } }
}

@MainActor
final class ProjectRepositoryRegistryTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let catalog: WorkspaceCatalog
        let scope: ProjectScope
        let records: URL
        let repository: URL
        let codec: RegistryBookmarkFake
        let registry: ProjectRepositoryRegistry
        static func make() async throws -> Self {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            let workspaces = root.appendingPathComponent("Workspaces"), records = root.appendingPathComponent("RepositoryAccess")
            let repository = root.appendingPathComponent("SyntheticRepository")
            for dir in [workspaces, records, repository] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
            let catalog = try WorkspaceCatalog(container: workspaces), workspace = try await catalog.createWorkspace(name: "Synthetic")
            let project = try await catalog.createProject(in: workspace.id, name: "Synthetic Project"), codec = RegistryBookmarkFake()
            let result = try await MacCommandCapture.run(executable: GitExecutableLocator.installed(), arguments: ["init", "--initial-branch=main"],
                directory: repository, environment: GitCaptureConfiguration.environment, timeout: .seconds(10), maximumBytes: 65_536)
            guard result.status == 0 else { throw RepositoryRegistrationError.invalidSelection }
            return Self(root: root, catalog: catalog, scope: project.scope, records: records, repository: repository, codec: codec,
                registry: try ProjectRepositoryRegistry(catalog: catalog, container: records, codec: codec))
        }
        var record: URL { records.appendingPathComponent("\(scope.workspaceID.rawValue).\(scope.projectID.rawValue).json") }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    func testRegistrationReopenSharedAccessAndRemovalBalanceGrants() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let saved = try await f.registry.register(f.repository, in: f.scope, expectedRevision: nil)
        XCTAssertEqual(saved.revision, 1); XCTAssertEqual(f.codec.state.withLock { $0.active }, 0)
        let reopened = try ProjectRepositoryRegistry(catalog: f.catalog, container: f.records, codec: f.codec)
        let registration = try await reopened.registration(in: f.scope); XCTAssertEqual(registration, saved)
        var first: RepositoryAccess? = try await f.registry.access(in: f.scope)
        var second: RepositoryAccess? = try await reopened.access(in: f.scope)
        XCTAssertEqual(first?.registration, saved); XCTAssertEqual(second?.registration, saved)
        XCTAssertEqual(f.codec.state.withLock { $0.active }, 2)
        do { _ = try await reopened.register(f.repository, in: f.scope, expectedRevision: 1); XCTFail("Replaced active access") }
        catch { XCTAssertEqual(error as? RepositoryRegistrationError, .busy) }
        do { try await reopened.remove(in: f.scope, expectedRevision: 1); XCTFail("Removed active registration") }
        catch { XCTAssertEqual(error as? RepositoryRegistrationError, .busy) }
        first = nil; second = nil
        XCTAssertEqual(f.codec.state.withLock { $0.active }, 0)
        let updated = try await reopened.register(f.repository, in: f.scope, expectedRevision: 1)
        XCTAssertEqual(updated.revision, 2); XCTAssertNotEqual(updated.id, saved.id)
        try await reopened.remove(in: f.scope, expectedRevision: 2)
        let missing = try await f.registry.registration(in: f.scope); XCTAssertNil(missing)
        XCTAssertTrue(FileManager.default.fileExists(atPath: f.repository.appendingPathComponent(".git").path))
    }
    func testMCPLaunchRetainsRegisteredGrantUntilClose() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        _ = try await f.registry.register(f.repository, in: f.scope, expectedRevision: nil)
        let environment = EnvironmentID(), id = UUID()
        let configurations = try await f.catalog.mcpConfigurationStore(for: MCPStdioConfiguration.self, in: f.scope)
        _ = try await configurations.save(MCPStdioConfiguration(id: id, scope: f.scope, environmentID: environment,
            name: "Synthetic", executable: "/usr/bin/true", arguments: [], workingDirectory: nil,
            enabled: true, directoryBase: .registeredRepository), in: f.scope, expectedRevision: nil)
        let rules = [PolicyRule(.runShell, .approval)]
        let policy = try PolicySnapshot(
            workspace: PolicyDocument(level: .workspace, workspaceID: f.scope.workspaceID, rules: rules),
            project: PolicyDocument(level: .project, workspaceID: f.scope.workspaceID, projectID: f.scope.projectID, rules: rules),
            environment: PolicyDocument(level: .environment, workspaceID: f.scope.workspaceID, projectID: f.scope.projectID,
                environmentID: environment, rules: rules), environmentKind: .test)
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [f.scope], environments: [environment],
            operations: [.runShell], canApprove: true, expiresAt: Date().addingTimeInterval(600))
        let approvals = try ApprovalStore(database: f.root.appendingPathComponent("operations.sqlite"), scope: f.scope, environmentID: environment)
        var access: RepositoryAccess? = try await f.registry.access(in: f.scope)
        let launch = try await MCPApprovedStdioLaunch.open(configurations: configurations, connectionID: id,
            scope: f.scope, environmentID: environment, workspaceRoot: f.root, repository: XCTUnwrap(access),
            authorities: [user], requesterID: user.id, approvals: approvals, currentPolicy: { policy })
        access = nil
        XCTAssertEqual(f.codec.state.withLock { $0.active }, 1)
        do { try await f.registry.remove(in: f.scope, expectedRevision: 1); XCTFail("Lost MCP repository lease") }
        catch { XCTAssertEqual(error as? RepositoryRegistrationError, .busy) }
        await launch.close()
        await launch.close()
        XCTAssertEqual(f.codec.state.withLock { $0.active }, 0)
        try await f.registry.remove(in: f.scope, expectedRevision: 1)
    }
    func testNativeMCPReviewsStartsPingsAndReleasesRegisteredGrant() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        _ = try await f.registry.register(f.repository, in: f.scope, expectedRevision: nil)
        let environment = EnvironmentID(), id = UUID()
        let configurations = try await f.catalog.mcpConfigurationStore(for: MCPStdioConfiguration.self, in: f.scope)
        _ = try await configurations.save(MCPStdioConfiguration(id: id, scope: f.scope, environmentID: environment,
            name: "Synthetic", executable: "/usr/bin/python3", arguments: ["-u", "-c", """
            import json, sys
            for line in sys.stdin:
                r = json.loads(line)
                if 'id' not in r: continue
                result = {'resultType':'complete'}
                if r['method'] == 'server/discover':
                    result.update({'supportedVersions':['2026-07-28'],'capabilities':{}})
                print(json.dumps({'jsonrpc':'2.0','id':r['id'],'result':result}), flush=True)
            """], workingDirectory: nil,
            enabled: true, directoryBase: .registeredRepository), in: f.scope, expectedRevision: nil)
        let rules = [PolicyRule(.runShell, .approval)]
        let policy = try PolicySnapshot(
            workspace: PolicyDocument(level: .workspace, workspaceID: f.scope.workspaceID, rules: rules),
            project: PolicyDocument(level: .project, workspaceID: f.scope.workspaceID, projectID: f.scope.projectID, rules: rules),
            environment: PolicyDocument(level: .environment, workspaceID: f.scope.workspaceID, projectID: f.scope.projectID,
                environmentID: environment, rules: rules), environmentKind: .test)
        let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [f.scope], environments: [environment],
            operations: [.runShell], canApprove: true, expiresAt: Date().addingTimeInterval(600))
        let approvals = try ApprovalStore(database: f.root.appendingPathComponent("operations.sqlite"), scope: f.scope, environmentID: environment)
        let launch = try await NativeMCPConnection.open(configurations: configurations, connectionID: id,
            scope: f.scope, environmentID: environment, workspaceRoot: f.root, repositories: f.registry,
            authorities: [user], requesterID: user.id, approvals: approvals, currentPolicy: { policy })
        guard case .approval(let pending) = try await launch.prepare() else { return XCTFail("Missing process review") }
        do { _ = try await launch.start(approvalID: pending.id); XCTFail("Unreviewed launch succeeded") }
        catch { XCTAssertTrue(error is AuthorizationError) }
        _ = try await launch.review(pending.id, approve: true, expectedSequence: pending.sequence)
        let server = try await launch.start(approvalID: pending.id)
        XCTAssertEqual(server.mode, .modern)
        try await launch.ping()
        XCTAssertEqual(f.codec.state.withLock { $0.active }, 1)
        do { try await f.registry.remove(in: f.scope, expectedRevision: 1); XCTFail("Lost MCP repository lease") }
        catch { XCTAssertEqual(error as? RepositoryRegistrationError, .busy) }
        await launch.close()
        await launch.close()
        XCTAssertEqual(f.codec.state.withLock { $0.active }, 0)
        try await f.registry.remove(in: f.scope, expectedRevision: 1)
    }
    func testNativeServiceRetainsRegistrationUntilShutdownWithoutStartingCodex() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        _ = try await f.registry.register(f.repository, in: f.scope, expectedRevision: nil)
        let agents = try await f.catalog.agentStore(in: f.scope), agent = try await agents.create(AgentTemplate.general.draft, in: f.scope)
        let settings = try await f.catalog.executionConfigurationStore(in: f.scope)
        let rules = [PolicyRule(.readEvidence, .allow), PolicyRule(.runReadOnlyAgent, .approval)], environmentID = EnvironmentID()
        let environment = ProjectEnvironment(id: environmentID, scope: f.scope, name: "Synthetic", kind: .test,
            policy: try PolicyDocument(level: .environment, workspaceID: f.scope.workspaceID, projectID: f.scope.projectID, environmentID: environmentID, rules: rules))
        _ = try await settings.save(.init(policy: PolicyDocument(level: .workspace, workspaceID: f.scope.workspaceID, rules: rules)),
            at: .workspace, in: f.scope, expectedRevision: nil)
        _ = try await settings.save(.init(environments: [environment], defaultEnvironmentID: environment.id,
            policy: PolicyDocument(level: .project, workspaceID: f.scope.workspaceID, projectID: f.scope.projectID, rules: rules)),
            at: .project, in: f.scope, expectedRevision: nil)
        let configuration = try await settings.preview(for: agent, in: f.scope)
        var access: RepositoryAccess? = try await f.registry.access(in: f.scope)
        let service = try await NativeRunService.open(database: f.root.appendingPathComponent("operations.sqlite"),
            repository: XCTUnwrap(access), executable: URL(fileURLWithPath: "/synthetic/unavailable-codex"), configuration: configuration)
        let registration = try XCTUnwrap(access?.registration)
        access = nil
        let instructionStore = try await f.catalog.instructionStore(in: f.scope)
        let instructions = try await instructionStore.preview(for: agent, in: f.scope)
        let prepared = try await service.prepare(instructions: instructions, configuration: configuration, task: "Inspect synthetic content")
        let records = try await service.evidenceRecords(for: prepared.runID)
        let artifact = try await service.artifact(XCTUnwrap(records.first?.id), for: prepared.runID)
        let snapshotText = try XCTUnwrap(artifact?.text)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshotText.utf8)) as? [String: Any])
        let location = try XCTUnwrap(json["location"] as? [String: Any])
        XCTAssertEqual(location["registrationID"] as? String, registration.id.uuidString)
        XCTAssertEqual(location["registrationRevision"] as? Int, registration.revision)
        XCTAssertEqual(location["selectedDirectory"] as? String, registration.path)
        for token in f.codec.state.withLock({ Array($0.urls.keys) }) { XCTAssertFalse(snapshotText.contains(token.base64EncodedString())) }
        do { try await f.registry.remove(in: f.scope, expectedRevision: 1); XCTFail("Service lost its grant") }
        catch { XCTAssertEqual(error as? RepositoryRegistrationError, .busy) }
        await service.shutdown()
        try await f.registry.remove(in: f.scope, expectedRevision: 1)
        XCTAssertEqual(f.codec.state.withLock { $0.active }, 0)
    }
    func testConcurrentRevisionWritersAndForeignCatalogScopesAreRejected() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let other = try ProjectRepositoryRegistry(catalog: f.catalog, container: f.records, codec: f.codec)
        let operations = [f.registry, other].map { registry in Task { try await registry.register(f.repository, in: f.scope, expectedRevision: nil) } }
        var success = 0
        for operation in operations {
            do { _ = try await operation.value; success += 1 }
            catch { XCTAssertTrue(error as? RepositoryRegistrationError == .busy || error as? RepositoryRegistrationError == .staleRevision) }
        }
        XCTAssertEqual(success, 1)
        do { _ = try await f.registry.register(f.repository, in: f.scope, expectedRevision: nil); XCTFail("Stale revision accepted") }
        catch { XCTAssertEqual(error as? RepositoryRegistrationError, .staleRevision) }
        let foreign = ProjectScope(workspaceID: WorkspaceID(), projectID: f.scope.projectID)
        do { _ = try await f.registry.access(in: foreign); XCTFail("Unknown workspace") } catch {}
        let missing = ProjectScope(workspaceID: f.scope.workspaceID, projectID: ProjectID())
        do { _ = try await f.registry.registration(in: missing); XCTFail("Unknown project") } catch {}
    }
    func testStaleRedirectedAndReplacedRootsNeverReturnAccess() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        _ = try await f.registry.register(f.repository, in: f.scope, expectedRevision: nil)
        f.codec.state.withLock { $0.stale = true }
        do { _ = try await f.registry.access(in: f.scope); XCTFail("Stale grant") }
        catch { XCTAssertEqual(error as? RepositoryRegistrationError, .staleBookmark) }
        let other = f.root.appendingPathComponent("Foreign")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
        f.codec.state.withLock { $0.stale = false; $0.redirect = other }
        do { _ = try await f.registry.access(in: f.scope); XCTFail("Redirected grant") }
        catch { XCTAssertEqual(error as? RepositoryRegistrationError, .changedDirectory) }
        f.codec.state.withLock { $0.redirect = nil }
        try FileManager.default.moveItem(at: f.repository, to: f.root.appendingPathComponent("Moved"))
        try FileManager.default.createDirectory(at: f.repository, withIntermediateDirectories: false)
        do { _ = try await f.registry.access(in: f.scope); XCTFail("Replaced directory") }
        catch { XCTAssertEqual(error as? RepositoryRegistrationError, .changedDirectory) }
        XCTAssertEqual(f.codec.state.withLock { $0.active }, 0)
    }
    func testMalformedForeignAndLinkedRecordsArePreserved() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        _ = try await f.registry.register(f.repository, in: f.scope, expectedRevision: nil)
        let original = try Data(contentsOf: f.record)
        for data in [Data("{bad".utf8), Data("{\"schemaVersion\":1,\"schemaVersion\":2}".utf8)] {
            try data.write(to: f.record)
            do { _ = try await f.registry.register(f.repository, in: f.scope, expectedRevision: 1); XCTFail("Malformed record replaced") }
            catch { XCTAssertEqual(error as? RepositoryRegistrationError, .invalidRecord) }
            XCTAssertEqual(try Data(contentsOf: f.record), data)
        }
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        json["scope"] = ["workspaceID": WorkspaceID().rawValue, "projectID": f.scope.projectID.rawValue]
        try JSONSerialization.data(withJSONObject: json).write(to: f.record)
        do { _ = try await f.registry.registration(in: f.scope); XCTFail("Foreign record") }
        catch { XCTAssertEqual(error as? RepositoryRegistrationError, .invalidRecord) }
        try FileManager.default.removeItem(at: f.record)
        let outside = f.root.appendingPathComponent("Unrelated"); try original.write(to: outside)
        try FileManager.default.createSymbolicLink(at: f.record, withDestinationURL: outside)
        do { _ = try await f.registry.registration(in: f.scope); XCTFail("Linked record") } catch {}
        XCTAssertEqual(try Data(contentsOf: outside), original)
    }
    func testUnsafeRepositoryAndStorageReplacementFailWithoutLeakingGrant() async throws {
        let f = try await Fixture.make(); defer { f.remove() }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await f.registry.register(f.repository, in: f.scope, expectedRevision: nil)
        }
        do { _ = try await cancelled.value; XCTFail("Cancelled registration") } catch { XCTAssertTrue(error is CancellationError) }
        let linked = f.root.appendingPathComponent("Linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: f.repository)
        do { _ = try await f.registry.register(linked, in: f.scope, expectedRevision: nil); XCTFail("Selected symlink") } catch {}
        try Data("[include]\npath = /synthetic/private-config\n".utf8).appendTo(f.repository.appendingPathComponent(".git/config"))
        do { _ = try await f.registry.register(f.repository, in: f.scope, expectedRevision: nil); XCTFail("External Git config") } catch {}
        XCTAssertEqual(f.codec.state.withLock { $0.active }, 0)
        try FileManager.default.moveItem(at: f.records, to: f.root.appendingPathComponent("OldRecords"))
        try FileManager.default.createDirectory(at: f.records, withIntermediateDirectories: false)
        do { _ = try await f.registry.registration(in: f.scope); XCTFail("Replaced storage root") }
        catch { XCTAssertEqual(error as? RepositoryRegistrationError, .storageUnavailable) }
    }
}
private extension Data {
    func appendTo(_ file: URL) throws { var original = try Data(contentsOf: file); original.append(self); try original.write(to: file) }
}
#endif
