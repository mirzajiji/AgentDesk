import Foundation
import XCTest
@testable import AgentDeskCore

final class ActionAuthorizationTests: XCTestCase {
    func testPreparedActionFingerprintBindsEveryIdentityAndExactPayload() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let resource = try ActionFingerprint(bytes: Data("resolved/synthetic/resource".utf8)), payload = try ActionFingerprint(bytes: Data("synthetic payload".utf8))
        let original = try PolicyAction(scope: scope, environmentID: environment, operation: .writeProject, resource: resource, payload: payload)
        let decoded = try JSONDecoder().decode(PolicyAction.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(try original.fingerprint, try decoded.fingerprint)
        let variants = [
            try PolicyAction(scope: scope, environmentID: environment, operation: .writeProject, resource: resource, payload: payload),
            try PolicyAction(id: original.id, scope: scope, environmentID: EnvironmentID(), operation: .writeProject, resource: resource, payload: payload),
            try PolicyAction(id: original.id, scope: ProjectScope(workspaceID: scope.workspaceID, projectID: ProjectID()), environmentID: environment, operation: .writeProject, resource: resource, payload: payload),
            try PolicyAction(id: original.id, scope: scope, environmentID: environment, operation: .externalMutation, resource: resource, payload: payload),
            try PolicyAction(id: original.id, scope: scope, environmentID: environment, operation: .writeProject, resource: payload, payload: resource)
        ]
        for changed in variants { XCTAssertNotEqual(try original.fingerprint, try changed.fingerprint) }
        let json = String(decoding: try JSONEncoder().encode(original), as: UTF8.self)
        XCTAssertFalse(json.contains("synthetic payload")); XCTAssertFalse(json.contains("resolved/synthetic/resource"))
        XCTAssertThrowsError(try PolicyAction(scope: scope, environmentID: environment, operation: .runReadOnlyAgent, resource: resource, payload: payload))
        XCTAssertNil(ActionFingerprint(rawValue: String(repeating: "z", count: 64)))
    }
    func testPolicyDocumentsRoundTripAndRejectDuplicateRulesFutureVersionsAndScopeWidening() throws {
        let workspace = WorkspaceID(), project = ProjectID(), environment = EnvironmentID()
        let rules = [PolicyRule(.readEvidence, .allow)]
        let root = try PolicyDocument(level: .workspace, workspaceID: workspace, rules: rules)
        let projectPolicy = try PolicyDocument(level: .project, workspaceID: workspace, projectID: project, rules: rules)
        let environmentPolicy = try PolicyDocument(level: .environment, workspaceID: workspace, projectID: project, environmentID: environment, rules: rules)
        let snapshot = try PolicySnapshot(workspace: root, project: projectPolicy, environment: environmentPolicy, environmentKind: .test)
        XCTAssertEqual(try JSONDecoder().decode(PolicySnapshot.self, from: JSONEncoder().encode(snapshot)), snapshot)
        XCTAssertEqual(root.disposition(for: .writeProject), .deny)
        XCTAssertThrowsError(try PolicyDocument(level: .workspace, workspaceID: workspace, projectID: project, rules: rules))
        XCTAssertThrowsError(try PolicyDocument(level: .environment, workspaceID: workspace, projectID: project, rules: rules))
        XCTAssertThrowsError(try PolicyDocument(level: .workspace, workspaceID: workspace, rules: rules + rules))
        let foreign = try PolicyDocument(level: .project, workspaceID: WorkspaceID(), projectID: project, rules: rules)
        XCTAssertThrowsError(try PolicySnapshot(workspace: root, project: foreign, environment: environmentPolicy, environmentKind: .test))
        let future = String(decoding: try JSONEncoder().encode(root), as: UTF8.self).replacingOccurrences(of: "\"schemaVersion\":1", with: "\"schemaVersion\":9")
        XCTAssertThrowsError(try JSONDecoder().decode(PolicyDocument.self, from: Data(future.utf8)))
    }
    func testApprovalRecordsRejectUnreviewedGrantsAndInvalidTimeBounds() throws {
        let digest = try ActionFingerprint(bytes: Data())
        let action = try PolicyAction(scope: ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID: EnvironmentID(), operation: .writeProject, resource: digest, payload: digest)
        let now = Date(timeIntervalSince1970: 1_000)
        func record(_ state: ApprovalState, until: Date, reviewer: UUID?, revision: UUID?) throws -> ApprovalRecord {
            try ApprovalRecord(id: UUID(), action: action, requesterID: UUID(), policyFingerprint: digest, state: state, sequence: 2,
                createdAt: now, expiresAt: until, updatedAt: now, reviewerID: reviewer, reviewerRevision: revision)
        }
        XCTAssertThrowsError(try record(.approved, until: now.addingTimeInterval(60), reviewer: nil, revision: nil))
        XCTAssertThrowsError(try record(.approved, until: now.addingTimeInterval(60), reviewer: UUID(), revision: nil))
        XCTAssertThrowsError(try record(.approved, until: now, reviewer: UUID(), revision: UUID()))
        XCTAssertThrowsError(try record(.expired, until: now.addingTimeInterval(60), reviewer: nil, revision: nil))
        XCTAssertThrowsError(try record(.approved, until: now.addingTimeInterval(86_401), reviewer: UUID(), revision: UUID()))
    }
}
