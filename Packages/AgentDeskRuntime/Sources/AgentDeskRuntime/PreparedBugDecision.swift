#if os(macOS)
import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// Exact trusted-native administrative review, not an agent/mobile mutation capability.
public struct PreparedBugDecision: Sendable {
    public let decision: BugReviewDecision
    public let proposedRevision: Int
    public let content: RedactedText
    public let expiresAt: Date
    let owner: UUID
    let review: PreparedBugReview
    let store: ProjectBugStore
    let proposal: BugProposal
}
#endif
