#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskRuntime

@MainActor final class MCPLaunchPolicyTests: XCTestCase {
    func testDiscoveryHasIndependentApprovalAndRejectsChangesDuringRead() async throws {
        for disposition: PolicyDisposition in [.deny, .allow, .approval] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic")
            let project = try await catalog.createProject(in: workspace.id, name: "Discovery")
            let scope = project.scope, environment = EnvironmentID(), id = UUID()
            let configurations = try await catalog.mcpConfigurationStore(for: MCPStdioConfiguration.self, in: scope)
            let path = try WorkspacePath(workspaceID: workspace.id, relativePath: "project")
            let config = try MCPStdioConfiguration(id: id, scope: scope, environmentID: environment,
                name: "Synthetic", executable: "/bin/example", workingDirectory: path, enabled: true)
            _ = try await configurations.save(config, in: scope, expectedRevision: nil)
            let rules = [PolicyRule(.runShell, .approval), PolicyRule(.readEvidence, disposition)]
            let policy = try PolicySnapshot(
                workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
                project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
                environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID,
                    environmentID: environment, rules: rules), environmentKind: .test)
            let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment],
                operations: [.runShell, .readEvidence], canApprove: true, expiresAt: Date().addingTimeInterval(600))
            let approvals = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
            let session = try await MCPLaunchPolicySession.open(configurations: configurations, connectionID: id,
                scope: scope, environmentID: environment, authorities: [user], requesterID: user.id, approvals: approvals,
                currentPolicy: { policy }, resolveResource: { _ in try .canonical("Synthetic") })
            let effects = Mutex(0)
            guard case .approval(let launch) = try await session.prepare() else { return XCTFail("Missing launch review") }
            _ = try await session.review(launch.id, approve: true, expectedSequence: launch.sequence)
            if disposition != .allow {
                do {
                    _ = try await session.discover(approvalID: launch.id) { effects.withLock { $0 += 1 } }
                    XCTFail("Launch approval authorized discovery")
                } catch { }
                XCTAssertEqual(effects.withLock { $0 }, 0)
            }
            if disposition == .deny {
                do { _ = try await session.discover { effects.withLock { $0 += 1 } }; XCTFail("Denied read executed") }
                catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
            } else {
                if disposition == .allow {
                    let result = try await session.discover { "synthetic catalog" }
                    guard case .executed(let value) = result else { return XCTFail("Allowed discovery did not execute") }
                    XCTAssertEqual(value, "synthetic catalog")
                }
                var approvalID: UUID?
                if disposition == .approval {
                    guard case .approval(let pending) = try await session.prepareDiscovery() else { return XCTFail("Missing discovery review") }
                    _ = try await session.reviewDiscovery(pending.id, approve: true, expectedSequence: pending.sequence)
                    approvalID = pending.id
                }
                do {
                    _ = try await session.discover(approvalID: approvalID) {
                        effects.withLock { $0 += 1 }
                        _ = try await configurations.save(config, in: scope, expectedRevision: 1)
                        return "stale claims"
                    }
                    XCTFail("Published claims after configuration changed")
                } catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
                XCTAssertEqual(effects.withLock { $0 }, 1)
            }
            await session.close()
            do { _ = try await session.prepareDiscovery(); XCTFail("Closed discovery prepared") }
            catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        }
    }
    func testDenialApprovalAndConfigurationChangesGateDispatch() async throws {
        for disposition: PolicyDisposition in [.deny, .allow, .approval] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            let catalog = try WorkspaceCatalog(container: root)
            let workspace = try await catalog.createWorkspace(name: "Synthetic")
            let project = try await catalog.createProject(in: workspace.id, name: "MCP policy")
            let scope = project.scope, environment = EnvironmentID(), id = UUID()
            let configurations = try await catalog.mcpConfigurationStore(for: MCPStdioConfiguration.self, in: scope)
            let path = try WorkspacePath(workspaceID: workspace.id, relativePath: "project")
            let config = try MCPStdioConfiguration(id: id, scope: scope, environmentID: environment, name: "Synthetic", executable: "/bin/example", workingDirectory: path, enabled: true)
            _ = try await configurations.save(config, in: scope, expectedRevision: nil)
            let rules = PolicyOperation.allCases.map { PolicyRule($0, disposition) }
            let policy = try PolicySnapshot(
                workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: rules),
                project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: rules),
                environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment, rules: rules), environmentKind: .test)
            let user = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [scope], environments: [environment],
                operations: [.runShell], canApprove: true, expiresAt: Date().addingTimeInterval(600))
            let approvals = try ApprovalStore(database: root.appendingPathComponent("operations.sqlite"), scope: scope, environmentID: environment)
            let mobile = try PolicyAuthority(id: UUID(), kind: .pairedDevice(UUID()), scopes: [scope], environments: [environment],
                operations: [.runShell], canApprove: true, expiresAt: Date().addingTimeInterval(600))
            let resolutions = Mutex(0)
            do {
                _ = try await MCPLaunchPolicySession.open(configurations: configurations, connectionID: id,
                    scope: scope, environmentID: environment, authorities: [mobile], requesterID: mobile.id,
                    approvals: approvals, currentPolicy: { policy }, resolveResource: { _ in
                        resolutions.withLock { $0 += 1 }; return try .canonical("Synthetic")
                    })
                XCTFail("Mobile launch session accepted")
            } catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
            XCTAssertEqual(resolutions.withLock { $0 }, 0)
            let session = try await MCPLaunchPolicySession.open(configurations: configurations, connectionID: id,
                scope: scope, environmentID: environment, authorities: [user], requesterID: user.id,
                approvals: approvals, currentPolicy: { policy }, resolveResource: { _ in try .canonical("Synthetic physical identity") })
            let effects = Mutex(0)
            do { _ = try await session.discover { effects.withLock { $0 += 1 } }; XCTFail("Missing discovery authority accepted") }
            catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
            do {
                _ = try await session.execute { effects.withLock { $0 += 1 } }
                XCTFail("Launch bypassed required approval")
            } catch {
                XCTAssertEqual(error as? AuthorizationError, disposition == .deny ? .denied : .approvalRequired)
            }
            XCTAssertEqual(effects.withLock { $0 }, 0)
            if disposition == .allow {
                guard case .approval(let pending) = try await session.prepare() else { return XCTFail("Missing mandatory approval") }
                _ = try await session.review(pending.id, approve: true, expectedSequence: pending.sequence)
                _ = try await session.execute(approvalID: pending.id) { effects.withLock { $0 += 1 } }
                XCTAssertEqual(effects.withLock { $0 }, 1)
                do { _ = try await session.execute(approvalID: pending.id) { effects.withLock { $0 += 1 } }; XCTFail("Approval reused") }
                catch { XCTAssertEqual(error as? AuthorizationError, .alreadyUsed) }
                XCTAssertEqual(effects.withLock { $0 }, 1)
            }
            if disposition == .approval {
                guard case .approval(let pending) = try await session.prepare() else { return XCTFail("Missing approval") }
                _ = try await session.review(pending.id, approve: true, expectedSequence: pending.sequence)
                let changed = try MCPStdioConfiguration(id: id, scope: scope, environmentID: environment, name: "Synthetic", executable: "/bin/changed", workingDirectory: path, enabled: true)
                _ = try await configurations.save(changed, in: scope, expectedRevision: 1)
                do { _ = try await session.execute(approvalID: pending.id) { effects.withLock { $0 += 1 } }; XCTFail("Changed configuration dispatched") }
                catch { XCTAssertEqual(error as? AuthorizationError, .stalePolicy) }
                XCTAssertEqual(effects.withLock { $0 }, 0)
            }
            await session.close()
            do { _ = try await session.execute { effects.withLock { $0 += 1 } }; XCTFail("Closed session dispatched") }
            catch { XCTAssertEqual(error as? AuthorizationError, .denied) }
        }
    }
}
#endif
