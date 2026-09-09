import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskSecurity

final class PolicyEngineTests: XCTestCase {
    private let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
    private let environment = EnvironmentID(), agent = AgentID(), run = RunID()
    private let now = Date(timeIntervalSince1970: 1_000)
    private func action(_ operation: PolicyOperation = .readEvidence) throws -> PolicyAction {
        let digest = try ActionFingerprint(bytes: Data("synthetic".utf8))
        return try PolicyAction(scope: scope, environmentID: environment, runID: run, agentID: agent, operation: operation, resource: digest, payload: digest)
    }
    private func policy(_ rules: [PolicyDisposition] = [.allow,.allow,.allow], production: Bool = false, locked: Bool = false) throws -> PolicySnapshot {
        func entries(_ value: PolicyDisposition) -> [PolicyRule] { PolicyOperation.allCases.map { PolicyRule($0, value) } }
        return try PolicySnapshot(
            workspace: PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: entries(rules[0])),
            project: PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID, rules: entries(rules[1])),
            environment: PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment, rules: entries(rules[2])),
            environmentKind: production ? .production : .test, workspaceLocked: locked)
    }
    private func authority(_ kind: PolicyAuthority.Kind = .localUser, operations: Set<PolicyOperation>? = nil,
                           expired: Bool = false, revoked: Bool = false) throws -> PolicyAuthority {
        try PolicyAuthority(id: UUID(), kind: kind, scopes: [scope], environments: [environment],
            operations: operations ?? Set(PolicyOperation.allCases), canApprove: true, expiresAt: now.addingTimeInterval(expired ? 0 : 600), revoked: revoked)
    }
    func testMostRestrictiveLevelWinsEveryCombination() throws {
        let values: [PolicyDisposition] = [.allow,.approval,.deny]
        for workspace in values { for project in values { for environment in values {
            let levels = [workspace,project,environment]
            let expected: PolicyDisposition = levels.contains(.deny) ? .deny : (levels.contains(.approval) ? .approval : .allow)
            XCTAssertEqual(try PolicyEngine.evaluate(action(), policy: policy(levels), authority: authority(), at: now).disposition, expected)
        } } }
    }
    func testMissingExpiredRevokedForeignAndUngrantedAuthorityFailClosed() throws {
        XCTAssertEqual(try PolicyEngine.evaluate(action(), policy: policy(), authority: nil, at: now).reason, .missingAuthority)
        XCTAssertEqual(try PolicyEngine.evaluate(action(), policy: policy(), authority: authority(expired: true), at: now).reason, .authorityExpired)
        XCTAssertEqual(try PolicyEngine.evaluate(action(), policy: policy(), authority: authority(revoked: true), at: now).reason, .authorityExpired)
        XCTAssertEqual(try PolicyEngine.evaluate(action(), policy: policy(), authority: authority(operations: []), at: now).reason, .operationNotGranted)
        let foreign = try PolicyAuthority(id: UUID(), kind: .localUser, scopes: [ProjectScope(workspaceID: WorkspaceID(), projectID: scope.projectID)], environments: [environment], operations: [.readEvidence], expiresAt: now.addingTimeInterval(60))
        XCTAssertEqual(try PolicyEngine.evaluate(action(), policy: policy(), authority: foreign, at: now).reason, .scopeMismatch)
        XCTAssertThrowsError(try PolicyEngine.evaluate(action(), policy: policy(), authority: authority(), at: Date(timeIntervalSince1970: .nan)))
    }
    func testMobileAndAgentsCannotElevateEvenWhenAllRulesAllow() throws {
        let mobile = try authority(.pairedDevice(UUID())), agent = try authority(.agent(agent))
        for operation in PolicyOperation.allCases where operation != .readEvidence {
            XCTAssertEqual(try PolicyEngine.evaluate(action(operation), policy: policy(), authority: mobile, at: now).reason, .mobileRestriction)
        }
        for operation: PolicyOperation in [.readSecret,.updateSecret,.changeConfiguration,.runShell] {
            XCTAssertEqual(try PolicyEngine.evaluate(action(operation), policy: policy(), authority: agent, at: now).reason, .agentRestriction)
            XCTAssertFalse(PolicyEngine.mayReview(try action(operation), authority: mobile, at: now))
        }
        XCTAssertFalse(PolicyEngine.mayReview(try action(.writeProject), authority: agent, at: now))
        XCTAssertTrue(PolicyEngine.mayReview(try action(.externalMutation), authority: mobile, at: now))
        XCTAssertEqual(try PolicyEngine.evaluate(action(), policy: policy(), authority: mobile, at: now).disposition, .allow)
    }
    func testProductionAndWorkspaceLockApplyBeforePermissiveRules() throws {
        for operation in PolicyOperation.allCases where operation.isMutation {
            XCTAssertEqual(try PolicyEngine.evaluate(action(operation), policy: policy(production: true), authority: authority(), at: now).reason, .productionRestriction)
        }
        XCTAssertEqual(try PolicyEngine.evaluate(action(.runReadOnlyAgent), policy: policy(locked: true), authority: authority(), at: now).reason, .workspaceLocked)
        XCTAssertEqual(try PolicyEngine.evaluate(action(.readEvidence), policy: policy(locked: true), authority: authority(), at: now).disposition, .allow)
        XCTAssertEqual(try PolicyEngine.evaluate(action(.readSecret), policy: policy(production: true), authority: authority(), at: now).disposition, .approval)
        XCTAssertEqual(try PolicyEngine.evaluate(action(.runShell), policy: policy(), authority: authority(), at: now).disposition, .approval)
    }
    func testPresetsKeepDestructiveAndSensitiveActionsExplicit() throws {
        let root = try PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: PolicyPreset.readOnly.rules)
        XCTAssertEqual(root.disposition(for: .readEvidence), .allow); XCTAssertEqual(root.disposition(for: .writeProject), .deny)
        let qa = try PolicyDocument(level: .workspace, workspaceID: scope.workspaceID, rules: PolicyPreset.qaSafe.rules)
        XCTAssertEqual(qa.disposition(for: .externalMutation), .approval); XCTAssertEqual(qa.disposition(for: .destructiveAction), .deny)
        XCTAssertEqual(qa.disposition(for: .readSecret), .deny)
    }
}
