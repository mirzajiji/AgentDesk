import Foundation
import XCTest
@testable import AgentDeskCore

final class RunWorkPlanTests: XCTestCase {
    private let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
    private let now = Date(timeIntervalSince1970: 1_000)

    func testFixedStageCompletionAndSkippedWorkHaveDeterministicProgress() throws {
        let a = WorkItemDefinition(kind: .stage, title: "Load requirements")
        let b = WorkItemDefinition(kind: .stage, title: "Optional check")
        var plan = try RunWorkPlan(scope: scope, runID: RunID(), mode: .fixedStages, definitions: [a, b])
        XCTAssertEqual(plan.overallProgress?.fractionCompleted, 0)
        plan = try plan.applying(.transition(a.id, to: .running), at: now)
        XCTAssertEqual(plan.overallProgress?.fractionCompleted, 0)
        plan = try plan.applying(.transition(a.id, to: .completed), at: now)
        XCTAssertEqual(plan.overallProgress?.fractionCompleted, 0.5)
        plan = try plan.applying(.transition(b.id, to: .skipped), at: now)
        XCTAssertEqual(plan.overallProgress?.fractionCompleted, 1)
        XCTAssertEqual(try plan.ending(with: .completed, at: now), plan)
    }

    func testOpenEndedProgressNeverInventsAPercentageAndCanAddDiscoveredStages() throws {
        var plan = try RunWorkPlan(scope: scope, runID: RunID(), mode: .openEnded, definitions: [])
        XCTAssertNil(plan.overallProgress)
        let stage = WorkItemDefinition(kind: .stage, title: "Investigate")
        plan = try plan.applying(.add(stage), at: now)
        plan = try plan.applying(.transition(stage.id, to: .running), at: now)
        plan = try plan.applying(.transition(stage.id, to: .completed), at: now)
        XCTAssertNil(plan.overallProgress)
        XCTAssertNil(try plan.ending(with: .completed, at: now).overallProgress)
    }

    func testStepsRequireActiveParentAndCompletionWaitsForChildrenAndMeasuredUnits() throws {
        let stage = WorkItemDefinition(kind: .stage, title: "Verify")
        let step = WorkItemDefinition(kind: .step, parentStageID: stage.id, title: "Run five checks")
        var plan = try RunWorkPlan(scope: scope, runID: RunID(), mode: .fixedStages, definitions: [stage, step])
        XCTAssertThrowsError(try plan.applying(.transition(step.id, to: .running), at: now))
        plan = try plan.applying(.transition(stage.id, to: .running), at: now)
        plan = try plan.applying(.transition(step.id, to: .running), at: now)
        plan = try plan.applying(.measure(step.id, completed: 2, total: 5), at: now)
        XCTAssertEqual(plan.items[1].progress?.fractionCompleted, 0.4)
        XCTAssertThrowsError(try plan.applying(.transition(step.id, to: .completed), at: now))
        XCTAssertThrowsError(try plan.applying(.transition(stage.id, to: .completed), at: now))
        plan = try plan.applying(.measure(step.id, completed: 5, total: 5), at: now)
        plan = try plan.applying(.transition(step.id, to: .completed), at: now)
        plan = try plan.applying(.transition(stage.id, to: .completed), at: now)
        XCTAssertEqual(plan.overallProgress?.fractionCompleted, 1)
        XCTAssertEqual(plan.items[1].startedAt, now); XCTAssertEqual(plan.items[1].finishedAt, now)
        XCTAssertThrowsError(try plan.applying(.transition(step.id, to: .running), at: now))
    }

    func testMeasurementsRejectChangedDenominatorsRegressionAndInvalidCounts() throws {
        let stage = WorkItemDefinition(kind: .stage, title: "Deterministic batch")
        var plan = try RunWorkPlan(scope: scope, runID: RunID(), mode: .fixedStages, definitions: [stage])
        plan = try plan.applying(.transition(stage.id, to: .running), at: now)
        plan = try plan.applying(.measure(stage.id, completed: 3, total: 10), at: now)
        for (completed, total) in [(2, 10), (4, 11), (-1, 10), (11, 10), (0, 0)] {
            XCTAssertThrowsError(try plan.applying(.measure(stage.id, completed: Int64(completed), total: Int64(total)), at: now))
        }
        XCTAssertThrowsError(try plan.applying(.measure(stage.id, completed: 4, total: 10), at: now.addingTimeInterval(-1)))
        XCTAssertThrowsError(try MeasuredProgress(completedUnits: 0, totalUnits: Int64.max))
        XCTAssertEqual(plan.items[0].progress?.completedUnits, 3)
    }

    func testFailureCancellationAndSkippingFinalizeChildrenWithoutErasingCompletedEvidence() throws {
        let stage = WorkItemDefinition(kind: .stage, title: "Checks")
        let a = WorkItemDefinition(kind: .step, parentStageID: stage.id, title: "Observed failure")
        let b = WorkItemDefinition(kind: .step, parentStageID: stage.id, title: "Blocked downstream")
        var plan = try RunWorkPlan(scope: scope, runID: RunID(), mode: .fixedStages, definitions: [stage, a, b])
        plan = try plan.applying(.transition(stage.id, to: .running), at: now)
        plan = try plan.applying(.transition(a.id, to: .running), at: now)
        plan = try plan.applying(.transition(a.id, to: .failed), at: now)
        XCTAssertThrowsError(try plan.ending(with: .completed, at: now))
        let failed = try plan.ending(with: .failed, at: now)
        XCTAssertEqual(failed.items.map(\.state), [.cancelled, .failed, .cancelled])
        XCTAssertEqual(failed.overallProgress?.fractionCompleted, 0)
        let pending = try RunWorkPlan(scope: scope, runID: RunID(), mode: .fixedStages, definitions: [stage, a, b])
        let skipped = try pending.applying(.transition(stage.id, to: .skipped), at: now)
        XCTAssertEqual(skipped.items.map(\.state), [.skipped, .skipped, .skipped])
    }

    func testFixedStageSetAndParentGraphCannotBeChangedIllegally() throws {
        let stage = WorkItemDefinition(kind: .stage, title: "Initial")
        let plan = try RunWorkPlan(scope: scope, runID: RunID(), mode: .fixedStages, definitions: [stage])
        XCTAssertThrowsError(try plan.applying(.add(WorkItemDefinition(kind: .stage, title: "Unexpected")), at: now))
        XCTAssertThrowsError(try plan.applying(.add(stage), at: now))
        XCTAssertThrowsError(try plan.applying(.add(WorkItemDefinition(kind: .step, parentStageID: WorkItemID(), title: "Foreign parent")), at: now))
        XCTAssertThrowsError(try RunWorkPlan(scope: scope, runID: RunID(), mode: .fixedStages, definitions: []))
        XCTAssertThrowsError(try RunWorkPlan(scope: scope, runID: RunID(), mode: .openEnded,
            definitions: [WorkItemDefinition(kind: .step, title: "Missing parent")]))
        XCTAssertThrowsError(try RunWorkPlan(scope: scope, runID: RunID(), mode: .openEnded,
            definitions: [WorkItemDefinition(kind: .stage, parentStageID: stage.id, title: "Invalid nested stage")]))
    }

    func testCodableRoundTripAndMalformedStateAreValidated() throws {
        let stage = WorkItemDefinition(kind: .stage, title: "Synthetic")
        let plan = try RunWorkPlan(scope: scope, runID: RunID(), mode: .fixedStages, definitions: [stage])
        let data = try JSONEncoder().encode(plan)
        XCTAssertEqual(try JSONDecoder().decode(RunWorkPlan.self, from: data), plan)
        let modified = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "pending", with: "completed")
        XCTAssertThrowsError(try JSONDecoder().decode(RunWorkPlan.self, from: Data(modified.utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(MeasuredProgress.self, from: Data("{\"completedUnits\":-1,\"totalUnits\":10}".utf8)))
    }

    func testMaximumPlanCanReachTerminalStateWithinSnapshotStorageBound() throws {
        let stages = (0..<32).map { _ in WorkItemDefinition(kind: .stage, title: String(repeating: "S", count: 160)) }
        let steps = (0..<128).map { index in WorkItemDefinition(kind: .step, parentStageID: stages[index / 4].id, title: String(repeating: "T", count: 160)) }
        var plan = try RunWorkPlan(scope: scope, runID: RunID(), mode: .fixedStages, definitions: stages + steps)
        for stage in stages { plan = try plan.applying(.transition(stage.id, to: .running), at: now) }
        for step in steps {
            plan = try plan.applying(.transition(step.id, to: .running), at: now)
            plan = try plan.applying(.measure(step.id, completed: 999_999_999_999, total: 1_000_000_000_000), at: now)
        }
        let cancelled = try plan.ending(with: .cancelled, at: now)
        XCTAssertLessThan(try JSONEncoder().encode(cancelled).count, 131_072)
        XCTAssertTrue(cancelled.items.allSatisfy { $0.state.isFinished })
        XCTAssertThrowsError(try RunWorkPlan(scope: scope, runID: RunID(), mode: .openEnded,
            definitions: stages + [WorkItemDefinition(kind: .stage, title: "Beyond limit")]))
    }
}
