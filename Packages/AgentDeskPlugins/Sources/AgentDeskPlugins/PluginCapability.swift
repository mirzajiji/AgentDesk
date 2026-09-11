import AgentDeskCore

/// Normalized integration operations. Discovery describes availability; it grants no authority.
public enum PluginCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case issuesRead, issuesCreate, issuesUpdate, issuesDelete
    case commentsRead, commentsWrite, attachmentsRead, attachmentsAdd

    public var policyOperation: PolicyOperation {
        switch self {
        case .issuesRead, .commentsRead, .attachmentsRead: .readEvidence
        case .issuesCreate, .issuesUpdate, .commentsWrite, .attachmentsAdd: .externalMutation
        case .issuesDelete: .destructiveAction
        }
    }
}
