import AgentDeskCore
import AgentDeskSecurity
import Foundation

public struct PreparedCityPayReport: Sendable {
    public let title: String
    public let content: RedactedText
    public let templateVersion: Int
    public let expiresAt: Date
    let owner: UUID
    let validate: @Sendable () async throws -> Void
}

struct CityPayReportService {
    static func prepare(_ review: PreparedBugReview, context: CityPayReportContext,
                        redactor: ContentRedactor, groupedIDs: [BugID] = [], problem: String? = nil) async throws -> PreparedCityPayReport {
        try await review.validate()
        guard review.readiness == nil, let incoming = review.snapshot.records.first(where: { $0.record.id == review.incomingID }) else {
            throw CityPayReportError.unverifiedFinding
        }
        guard groupedIDs.count <= 15, Set(groupedIDs).count == groupedIDs.count, !groupedIDs.contains(review.incomingID) else {
            throw CityPayReportError.invalidContent
        }
        let grouped = try groupedIDs.map { id in
            guard let input = review.snapshot.records.first(where: { $0.record.id == id }) else { throw BugRegistryError.unavailableReference }
            return input
        }
        guard ([incoming] + grouped).allSatisfy({ $0.record.content.ticket == nil }) else { throw CityPayReportError.duplicateReviewRequired }
        let included = Set(groupedIDs + [review.incomingID])
        for match in review.matches where !included.contains(match.existingID) && [.duplicate, .possibleDuplicate].contains(match.result.classification) {
            // A fresh explicit distinct decision can resolve this particular comparison. It cannot
            // authorize another candidate, survive a behavior edit, or silently become external approval.
            let decision = review.decisions.first { $0.existingID == match.existingID }
            let existing = review.snapshot.records.first { $0.record.id == match.existingID }
            guard decision?.resolution == .distinct, decision?.existingID == match.existingID,
                  decision?.existingRevision == existing?.record.revision else { throw CityPayReportError.duplicateReviewRequired }
        }
        let sanitize: (String) throws -> String = { try redactor.redactJSON($0, in: redactor.context).text }
        let report: CityPayBugReport
        if grouped.isEmpty { report = try CityPayBugReport.prepare(incoming, context: context, sanitizeJSON: sanitize) }
        else {
            guard let problem else { throw CityPayReportError.missingContext }
            report = try CityPayBugReport.prepareGroup([incoming] + grouped, context: context, problem: problem, sanitizeJSON: sanitize)
        }
        // Rendering is prose, not a JSON string containing a second JSON document. JSON redaction of
        // a whole section string would discard nonsecret siblings alongside an already-masked field.
        let body = (["Title\n\(report.title)"] + report.sections.map { "\($0.name.rawValue)\n\($0.text)" }).joined(separator: "\n\n")
        let safe = try redactor.redactText(body, in: redactor.context)
        guard safe.text.utf8.count <= 32_768 else { throw BugRegistryError.limitExceeded }
        let title = try redactor.redactText(report.title, in: redactor.context).text
        try await review.validate()
        return .init(title: title, content: safe, templateVersion: CityPayBugSkill.templateVersion,
            expiresAt: review.expiresAt, owner: review.owner, validate: review.validate)
    }
}
