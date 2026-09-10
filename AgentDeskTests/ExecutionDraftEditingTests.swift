#if os(macOS)
import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDesk

@MainActor
final class ExecutionDraftEditingTests: XCTestCase {
    func testWorkspacePolicyProposalCanApplyAdvancedSchemaFromJSONSerialization() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let policy = try PolicyDocument(level: .workspace, workspaceID: scope.workspaceID,
            rules: [PolicyRule(.readEvidence, .allow), PolicyRule(.runReadOnlyAgent, .approval)])
        let draft = ExecutionConfigurationDraft(settings: .init(maximumSteps: 30, timeoutSeconds: 600,
            maximumOutputBytes: 65_536, accessCeiling: .readOnly), policy: policy)
        var document = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(ExecutionDraftEditing.json(draft).utf8)) as? [String: Any])
        var settings = try XCTUnwrap(document["settings"] as? [String: Any])
        settings["modelIdentifier"] = "synthetic-configured-model"
        settings["allowedModelIdentifiers"] = ["synthetic-configured-model"]
        settings["outputSchema"] = ["type": "object", "properties": ["ok": ["type": "boolean"]],
            "required": ["ok"], "additionalProperties": false] as [String: Any]
        document["settings"] = settings
        let text = String(decoding: try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys]), as: UTF8.self)
        let decoded = try ExecutionDraftEditing.decode(text, at: .workspace, in: scope)
        XCTAssertEqual(decoded.settings.modelIdentifier, "synthetic-configured-model")
        XCTAssertEqual(decoded.settings.outputSchema, .object(["ok": .boolean]))
        XCTAssertEqual(decoded.policy, policy)
    }
    func testAdvancedSettingsRoundTripPreservesRestrictionsSchemaAndEnvironmentPolicy() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environmentID = EnvironmentID()
        let policy = try PolicyDocument(level: .environment, workspaceID: scope.workspaceID, projectID: scope.projectID,
            environmentID: environmentID, rules: [PolicyRule(.readEvidence, .allow), PolicyRule(.runReadOnlyAgent, .approval)])
        let environment = ProjectEnvironment(id: environmentID, scope: scope, name: "Synthetic", kind: .test,
            constraints: .init(timeoutSeconds: 30, allowedModelIdentifiers: ["synthetic-model"], accessCeiling: .readOnly), policy: policy)
        let draft = ExecutionConfigurationDraft(settings: .init(modelIdentifier: "synthetic-model", maximumOutputBytes: 4_096,
            allowedModelIdentifiers: ["synthetic-model"], allowedEnvironmentIDs: [environmentID], outputSchema: .object(["ok": .boolean])),
            environments: [environment], defaultEnvironmentID: environmentID)
        let json = try ExecutionDraftEditing.json(draft)
        let decoded = try ExecutionDraftEditing.decode(json, at: .project, in: scope)
        XCTAssertEqual(decoded, draft)
        XCTAssertEqual(decoded.environments.first?.policy?.revision, policy.revision)
    }
    func testAdvancedEditorRejectsMalformedDuplicateUnknownOversizedAndForeignConfiguration() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let original = ExecutionConfigurationDraft(settings: .init(timeoutSeconds: 60))
        let json = try ExecutionDraftEditing.json(original)
        for invalid in ["{bad", String(repeating: " ", count: 262_145) + json,
            json.replacingOccurrences(of: "\"timeoutSeconds\" : 60", with: "\"timeoutSeconds\" : 60, \"timeoutSeconds\" : 1"),
            json.replacingOccurrences(of: "\"timeoutSeconds\" : 60", with: "\"timeuotSeconds\" : 60"),
            json.replacingOccurrences(of: "\"timeoutSeconds\" : 60", with: "\"timeoutSeconds\" : 0")] {
            XCTAssertNotEqual(invalid, json)
            XCTAssertThrowsError(try ExecutionDraftEditing.decode(invalid, at: .workspace, in: scope))
        }
        let foreign = ProjectEnvironment(scope: .init(workspaceID: WorkspaceID(), projectID: ProjectID()), name: "Foreign")
        let foreignJSON = try ExecutionDraftEditing.json(.init(environments: [foreign], defaultEnvironmentID: foreign.id))
        XCTAssertThrowsError(try ExecutionDraftEditing.decode(foreignJSON, at: .project, in: scope))
        let project = ProjectEnvironment(scope: scope, name: "Project")
        let projectJSON = try ExecutionDraftEditing.json(.init(environments: [project], defaultEnvironmentID: project.id))
        XCTAssertThrowsError(try ExecutionDraftEditing.decode(projectJSON, at: .workspace, in: scope))
        XCTAssertEqual(try ExecutionDraftEditing.decode(json, at: .workspace, in: scope), original)
    }
    func testRemovingEnvironmentClearsOnlyItsDefaultAndPreservesOtherSettings() {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let first = ProjectEnvironment(scope: scope, name: "First"), second = ProjectEnvironment(scope: scope, name: "Second")
        let limits = ExecutionSettings(timeoutSeconds: 45, allowedEnvironmentIDs: [first.id, second.id], outputSchema: .object(["ok": .boolean]))
        var draft = ExecutionConfigurationDraft(settings: limits, environments: [first, second], defaultEnvironmentID: first.id)
        ExecutionDraftEditing.removeEnvironment(second.id, from: &draft)
        XCTAssertEqual(draft.defaultEnvironmentID, first.id); XCTAssertEqual(draft.environments, [first])
        ExecutionDraftEditing.removeEnvironment(first.id, from: &draft)
        XCTAssertNil(draft.defaultEnvironmentID); XCTAssertTrue(draft.environments.isEmpty)
        XCTAssertEqual(draft.settings, limits) // A form edit cannot silently widen a saved allowlist.
    }
    func testPermissionEditPreservesOtherRulesAndRefusesForeignPolicy() throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let existing = try PolicyDocument(level: .project, workspaceID: scope.workspaceID, projectID: scope.projectID,
            rules: [PolicyRule(.readEvidence, .allow), PolicyRule(.runReadOnlyAgent, .deny), PolicyRule(.externalMutation, .approval)])
        let unchanged = try ExecutionDraftEditing.change(.readEvidence, to: .allow, policy: existing, scope: scope, level: .project, environmentID: nil)
        XCTAssertEqual(unchanged, existing)
        let changed = try ExecutionDraftEditing.change(.runReadOnlyAgent, to: .approval, policy: existing, scope: scope, level: .project, environmentID: nil)
        XCTAssertNotEqual(changed.revision, existing.revision)
        XCTAssertEqual(changed.disposition(for: .readEvidence), .allow)
        XCTAssertEqual(changed.disposition(for: .externalMutation), .approval)
        XCTAssertEqual(changed.disposition(for: .runReadOnlyAgent), .approval)
        XCTAssertEqual(changed.disposition(for: .runShell), .deny)
        XCTAssertThrowsError(try ExecutionDraftEditing.change(.readEvidence, to: .allow, policy: existing,
            scope: .init(workspaceID: WorkspaceID(), projectID: scope.projectID), level: .project, environmentID: nil))
        XCTAssertThrowsError(try ExecutionDraftEditing.change(.readEvidence, to: .allow, policy: existing,
            scope: scope, level: .workspace, environmentID: nil))
    }
}
#endif
