import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// Candidate evidence only. Identical comments may predate or be unrelated to the attempted write.
public struct JiraCommentCandidates: Sendable, Equatable {
    public let matchingIDs: [String]
    public let inspectedCount: Int
    public let nextStartAt: Int?
}

enum JiraCommentReconciliation {
    /// The trusted caller must obtain this page from an authorized read of the draft's target.
    static func compare(_ draft: JiraCommentDraft, page: JiraCommentsPage) throws -> JiraCommentCandidates {
        try compare(draft, content: page.content, nextStartAt: page.nextStartAt)
    }
    static func compare(_ draft: JiraCommentDraft, content: RedactedText, nextStartAt: Int?) throws -> JiraCommentCandidates {
        guard content.context == draft.content.context else { throw AuthorizationError.scopeMismatch }
        guard content.text.utf8.count <= 262_144,
              let object = try JSONSerialization.jsonObject(with: Data(content.text.utf8)) as? [String: Any],
              let comments = object["comments"] as? [[String: Any]], comments.count <= 100,
              let payload = try JSONSerialization.jsonObject(with: draft.body) as? [String: Any],
              let expected = payload["body"] as? [String: Any] else { throw JiraServiceError.invalidResponse }
        let canonical = try JSONSerialization.data(withJSONObject: expected, options: [.sortedKeys])
        var seen = Set<String>(), matching: [String] = []
        for comment in comments {
            guard let id = comment["id"] as? String, !id.isEmpty, id.utf8.count <= 128,
                  id.utf8.allSatisfy({ (48...57).contains($0) }), seen.insert(id).inserted,
                  let body = comment["body"] as? [String: Any] else { throw JiraServiceError.invalidResponse }
            if try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) == canonical { matching.append(id) }
        }
        return JiraCommentCandidates(matchingIDs: matching, inspectedCount: comments.count, nextStartAt: nextStartAt)
    }
}
