import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// Prepared text only. No network request or external ticket mutation occurs.
public struct BugTicketEvidenceDraft: Sendable {
    public let incomingID: BugID
    public let existingID: BugID
    public let ticket: ExternalBugTicket
    public let content: RedactedText
    public let expiresAt: Date
    let owner: UUID
    let validate: @Sendable () async throws -> Void
}

extension BugReviewService {
    static func ticketEvidence(_ review: PreparedBugReview, existingID: BugID, redactor: ContentRedactor) async throws -> BugTicketEvidenceDraft {
        try await review.validate()
        guard review.readiness == nil,
              let incoming = review.snapshot.records.first(where: { $0.record.id == review.incomingID }),
              let existing = review.snapshot.records.first(where: { $0.record.id == existingID }),
              let match = review.matches.first(where: { $0.existingID == existingID }),
              let ticket = existing.record.content.ticket, !existing.staleRequirements,
              existing.record.content.assessment == .observed else { throw BugRegistryError.invalidReview }
        let decision = review.decisions.first { $0.existingID == existingID }
        let reviewedDuplicate = decision?.resolution == .duplicate && decision?.existingID == existingID &&
            decision?.existingRevision == existing.record.revision
        guard match.result.classification == .duplicate || reviewedDuplicate else { throw BugRegistryError.invalidReview }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes]
        let ticketText = String(decoding: try encoder.encode(ticket), as: UTF8.self)
        let safeTicket = try redactor.redactJSON(ticketText, in: redactor.context)
        guard try JSONDecoder().decode(ExternalBugTicket.self, from: Data(safeTicket.text.utf8)) == ticket else { throw BugRegistryError.invalidReview }
        // Read only the selected source from the already sanitized packet. Never copy unrelated candidates.
        let packet = try JSONSerialization.jsonObject(with: Data(review.content.text.utf8)) as? [String: Any]
        guard let sources = packet?["sources"] as? [[String: Any]],
              let source = sources.first(where: { ($0["id"] as? String) == review.incomingID.rawValue }) else { throw BugRegistryError.invalidReview }
        let sourceBytes = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        let body = """
        Additional evidence for existing ticket \(ticket.key ?? ticket.url ?? "")

        Finding: \(review.incomingID), revision \(incoming.record.revision)
        Existing registry record: \(existingID), revision \(existing.record.revision)
        Environment: \(review.environment)
        Review basis: \(reviewedDuplicate ? "Explicit local duplicate review" : "Exact deterministic behavior comparison")
        Matching fields: \(match.result.matchingFields.joined(separator: ", "))
        Differing fields: \(match.result.differingFields.isEmpty ? "None" : match.result.differingFields.joined(separator: ", "))

        The source below preserves observation and interpretation labels, current requirement versions,
        reproduction details and verified evidence references. Manual observations remain user-attested.
        This draft adds evidence to the existing ticket; it does not create a new defect or verify blocked behavior.

        \(String(decoding: sourceBytes, as: UTF8.self))
        """
        let safe = try redactor.redactText(body, in: redactor.context)
        guard safe.text.utf8.count <= 32_768 else { throw BugRegistryError.limitExceeded }
        try await review.validate()
        return .init(incomingID: review.incomingID, existingID: existingID, ticket: ticket, content: safe,
            expiresAt: review.expiresAt, owner: review.owner, validate: review.validate)
    }
}
