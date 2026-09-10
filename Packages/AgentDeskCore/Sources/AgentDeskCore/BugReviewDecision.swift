import Foundation

public struct BugReviewDecision: Codable, Equatable, Sendable {
    public enum Resolution: String, Codable, Sendable { case duplicate, related, distinct }
    public let sourceID: BugID
    public let sourceRevision: Int
    public let existingID: BugID
    public let existingRevision: Int
    public let suggested: BugComparisonResult.Classification
    public let resolution: Resolution
    public let reason: String
    public var isOverride: Bool { resolution.rawValue != suggested.rawValue }
    func validate(sourceID: BugID?) throws {
        guard self.sourceID == sourceID, self.sourceID != existingID,
              (1...1_000_000).contains(sourceRevision), (1...1_000_000).contains(existingRevision) else { throw BugRegistryError.invalidReview }
        try RequirementDraft.checkText(reason, maximum: 4_096)
    }
}
