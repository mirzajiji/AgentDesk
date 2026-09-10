#if os(macOS)
import AgentDeskCore
import Foundation

/// Deterministic edits shared by the native form and its advanced JSON editor.
enum ExecutionDraftEditing {
    static func json(_ draft: ExecutionConfigurationDraft) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(draft), as: UTF8.self)
    }
    static func decode(_ text: String, at level: ExecutionConfigurationLevel, in scope: ProjectScope) throws -> ExecutionConfigurationDraft {
        guard text.utf8.count <= 262_144 else { throw ExecutionConfigurationError.invalidConfiguration }
        let draft = try ConfigurationJSON.decode(ExecutionConfigurationDraft.self, from: Data(text.utf8))
        try draft.validate(at: level, in: scope)
        return draft
    }
    static func removeEnvironment(_ id: EnvironmentID, from draft: inout ExecutionConfigurationDraft) {
        if draft.defaultEnvironmentID == id { draft.defaultEnvironmentID = nil }
        draft.environments.removeAll { $0.id == id }
    }
    static func change(_ operation: PolicyOperation, to disposition: PolicyDisposition, policy: PolicyDocument?,
                       scope: ProjectScope, level: PolicyLevel, environmentID: EnvironmentID?) throws -> PolicyDocument {
        let projectID = level == .workspace ? nil : scope.projectID
        if let policy {
            try policy.validate()
            guard policy.workspaceID == scope.workspaceID, policy.projectID == projectID,
                  policy.level == level, policy.environmentID == environmentID else { throw ExecutionConfigurationError.scopeMismatch }
            if policy.disposition(for: operation) == disposition { return policy }
        }
        let rules = (policy?.rules ?? []).filter { $0.operation != operation } + [PolicyRule(operation, disposition)]
        return try PolicyDocument(level: level, workspaceID: scope.workspaceID, projectID: projectID,
                                  environmentID: environmentID, rules: rules)
    }
}
#endif
