import AgentDeskCore
import XCTest
@testable import AgentDeskRuntime

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
}
