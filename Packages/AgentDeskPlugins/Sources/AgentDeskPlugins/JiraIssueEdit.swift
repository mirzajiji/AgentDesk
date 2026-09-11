import AgentDeskSecurity
import Foundation

/// Constructs only the reviewed field replacement. Authorization and observed-state
/// revalidation belong to the runtime before this internal boundary is dispatched.
enum JiraIssueEdit {
    static func make(_ draft: JiraIssueEditDraft, resource: JiraCloudResource,
                     tokens: JiraOAuthTokens, now: Date) throws -> URLRequest {
        guard now.timeIntervalSince1970.isFinite, tokens.expiresAt > now else {
            throw JiraServiceError.authenticationRequired
        }
        guard tokens.scopes.contains("write:jira-work"), resource.scopes.contains("write:jira-work") else {
            throw JiraServiceError.accessDenied
        }
        var request = URLRequest(url: resource.apiOrigin.appendingPathComponent("rest/api/3/issue")
            .appendingPathComponent(draft.identifier))
        request.httpMethod = "PUT"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        tokens.accessToken.withBytes {
            request.setValue("Bearer " + String(decoding: $0, as: UTF8.self), forHTTPHeaderField: "Authorization")
        }
        request.httpBody = draft.body
        return request
    }

    /// Acknowledgment only; this does not assert a subsequent read or atomic state comparison.
    static func validateAcknowledgment(_ response: JiraHTTPResponse) throws {
        if [400, 401, 403, 404, 409, 413, 422, 429].contains(response.status) {
            throw JiraMutationError.rejected(status: response.status)
        }
        // We do not request returnIssue. Unexpected success codes are not proof of
        // this operation's acknowledgment and must never trigger an automatic retry.
        guard response.status == 204, response.body.isEmpty else {
            throw JiraMutationError.outcomeUnknown
        }
    }
}

/// Jira acknowledged the update; later state may change independently.
public struct JiraIssueEditReceipt: Sendable {
    public let identifier: String
}
