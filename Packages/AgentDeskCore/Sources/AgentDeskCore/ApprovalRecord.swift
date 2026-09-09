import Foundation

public enum ApprovalState: String, Codable, Sendable {
    case pending, approved, rejected, modified, expired, consumed
}

/// Operational approval data contains identities and digests, not raw task/command/secret content.
public struct ApprovalRecord: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let action: PolicyAction
    public let requesterID: UUID
    public let policyFingerprint: ActionFingerprint
    public let state: ApprovalState
    public let sequence: Int64
    public let createdAt: Date
    public let expiresAt: Date
    public let updatedAt: Date
    public let reviewerID: UUID?
    public let reviewerRevision: UUID?

    public init(id: UUID, action: PolicyAction, requesterID: UUID, policyFingerprint: ActionFingerprint, state: ApprovalState,
                sequence: Int64, createdAt: Date, expiresAt: Date, updatedAt: Date, reviewerID: UUID?, reviewerRevision: UUID?) throws {
        try action.validate()
        guard (reviewerID == nil) == (reviewerRevision == nil), sequence > 0, sequence < Int64.max, [createdAt, expiresAt, updatedAt].allSatisfy({ $0.timeIntervalSince1970.isFinite }),
              expiresAt > createdAt, expiresAt.timeIntervalSince(createdAt) <= 86_400,
              updatedAt >= createdAt, state == .pending || state == .expired || reviewerID != nil else { throw AuthorizationError.invalidInput }
        guard state != .pending || (sequence == 1 && reviewerID == nil && updatedAt == createdAt),
              state != .expired || updatedAt >= expiresAt,
              ![.approved, .consumed].contains(state) || updatedAt < expiresAt else { throw AuthorizationError.invalidInput }
        self.id = id; self.action = action; self.requesterID = requesterID; self.policyFingerprint = policyFingerprint
        self.state = state; self.sequence = sequence; self.createdAt = createdAt; self.expiresAt = expiresAt
        self.updatedAt = updatedAt; self.reviewerID = reviewerID; self.reviewerRevision = reviewerRevision
    }
}
public struct ApprovalEvent: Equatable, Sendable {
    public let approvalID: UUID
    public let scope: ProjectScope
    public let environmentID: EnvironmentID
    public let sequence: Int64
    public let state: ApprovalState
    public let recordedAt: Date
    public let reviewerID: UUID?
    public let reviewerRevision: UUID?
    public init(approvalID: UUID, scope: ProjectScope, environmentID: EnvironmentID, sequence: Int64,
                state: ApprovalState, recordedAt: Date, reviewerID: UUID?, reviewerRevision: UUID?) {
        self.approvalID = approvalID; self.scope = scope; self.environmentID = environmentID; self.sequence = sequence
        self.state = state; self.recordedAt = recordedAt; self.reviewerID = reviewerID; self.reviewerRevision = reviewerRevision
    }
}
