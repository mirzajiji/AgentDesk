import AgentDeskCore
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class ExecutionRequestTests: XCTestCase {
    func testRequestRejectsMalformedBoundsAndModelFlagsBeforeExecution() throws {
        let identity = ExecutionIdentity(scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), runID: RunID(), agentID: AgentID(), environmentID: EnvironmentID())
        func request(task: String = "Read synthetic data", instructions: String = "Report evidence", model: String? = nil, timeout: Duration = .seconds(30), activities: Int = 100) -> ExecutionRequest {
            ExecutionRequest(identity: identity, instructions: instructions, task: task, model: model, timeout: timeout, maximumActivities: activities)
        }
        XCTAssertNoThrow(try request(task: "Literal $(touch nope); 🧪", model: "configured-model:version").validate())
        for invalid in [request(task: " \n"), request(task: "abc\0def"), request(task: String(repeating: "x", count: 98_305)),
                        request(instructions: ""), request(model: "--unsafe flag"), request(model: ""),
                        request(timeout: .zero), request(timeout: .seconds(3_601)), request(activities: 0), request(activities: 1_001)] {
            XCTAssertThrowsError(try invalid.validate()) { XCTAssertEqual($0 as? ExecutionProviderError, .invalidRequest) }
        }
    }
    func testStoredPreviewBuildsExactRequestAndDoesNotSilentlyDowngradeWriteIntent() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try WorkspaceCatalog(container: root)
        let workspace = try await catalog.createWorkspace(name: "Synthetic")
        let project = try await catalog.createProject(in: workspace.id, name: "Synthetic project")
        let agents = try await catalog.agentStore(in: project.scope)
        let agent = try await agents.create(AgentTemplate.general.draft, in: project.scope)
        let store = try await catalog.executionConfigurationStore(in: project.scope)
        let environment = ProjectEnvironment(scope: project.scope, name: "Test", kind: .test)
        let schema = OutputSchema.object(["ok": .boolean])
        _ = try await store.save(.init(settings: .init(modelIdentifier: "synthetic-model", maximumSteps: 10, timeoutSeconds: 60,
            maximumOutputBytes: 1_000, outputSchema: schema), environments: [environment], defaultEnvironmentID: environment.id),
            at: .project, in: project.scope, expectedRevision: nil)
        let preview = try await store.preview(for: agent, in: project.scope)
        let run = RunID(), request = try ExecutionRequest(configuration: preview, runID: run, instructions: "Report evidence", task: "Check synthetic input")
        XCTAssertEqual(request.identity, ExecutionIdentity(scope: project.scope, runID: run, agentID: agent.id, environmentID: environment.id))
        XCTAssertEqual(request.model, "synthetic-model"); XCTAssertEqual(request.timeout, .seconds(60))
        XCTAssertEqual(request.maximumActivities, 10); XCTAssertEqual(request.maximumOutputBytes, 1_000); XCTAssertEqual(request.outputSchema, schema)
        var draft = agent.draft; draft.profile.requestedAccess = .workspaceWrite
        let writer = try await agents.update(agent.id, in: project.scope, expectedRevision: 1, draft: draft)
        let writePreview = try await store.preview(for: writer, in: project.scope)
        XCTAssertThrowsError(try ExecutionRequest(configuration: writePreview, runID: RunID(), instructions: "Write", task: "Write")) {
            XCTAssertEqual($0 as? ExecutionProviderError, .unsupportedAccess)
        }
    }
    func testInvalidOutputContractsFailBeforeLaunch() {
        let identity = ExecutionIdentity(scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), runID: RunID(), agentID: AgentID(), environmentID: EnvironmentID())
        for (bytes, schema) in [(0, nil), (262_145, nil), (1_000, OutputSchema.boolean), (1_000, .object(["bad": .string(minimum: 10, maximum: 1, choices: nil)]))] {
            let request = ExecutionRequest(identity: identity, instructions: "Evidence", task: "Synthetic", model: nil, timeout: .seconds(10),
                maximumActivities: 10, maximumOutputBytes: bytes, outputSchema: schema)
            XCTAssertThrowsError(try request.validate()) { XCTAssertEqual($0 as? ExecutionProviderError, .invalidRequest) }
        }
    }

}
