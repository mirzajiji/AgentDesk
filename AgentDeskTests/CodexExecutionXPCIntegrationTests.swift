#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskRuntime

/// Exercises the real signed app/helper connection without a CLI account or model invocation.
@MainActor
final class CodexExecutionXPCIntegrationTests: XCTestCase {
    func testSignedHelperAcceptsBoundRequestAndReturnsTypedUnavailableExecutable() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let identity = ExecutionIdentity(scope: scope, runID: RunID(), agentID: AgentID(), environmentID: EnvironmentID())
        let resource = try GitRepositoryFiles(root: root).resource(in: scope)
        let request = ExecutionRequest(identity: identity, instructions: "Inspect synthetic content", task: "Report evidence",
            model: nil, timeout: .seconds(10), maximumActivities: 1)
        let start = try CodexExecutionStart(request: request, directory: root,
            executable: root.appendingPathComponent("intentionally-unavailable-codex"), resource: resource)
        let connection = CodexExecutionHostConnection()
        do {
            let accepted = try await CodexExecutionHostWire.decode(CodexExecutionHostReply.self,
                from: connection.send(CodexExecutionHostWire.encode(CodexExecutionHostRequest(.start(start)))))
            if case .started(let actualIdentity, let actualResource) = accepted {
                XCTAssertEqual(actualIdentity, identity); XCTAssertEqual(actualResource, resource)
            } else { XCTFail("The signed helper did not acknowledge the prepared identity") }
            let result = try await CodexExecutionHostWire.decode(CodexExecutionHostReply.self,
                from: connection.send(CodexExecutionHostWire.encode(CodexExecutionHostRequest(.next(runID: identity.runID, afterSequence: 0)))))
            if case .failed(.unavailable) = result {} else { XCTFail("Expected typed unavailable executable") }
            connection.close()
        } catch { connection.close(); throw error }
    }
}
#endif
