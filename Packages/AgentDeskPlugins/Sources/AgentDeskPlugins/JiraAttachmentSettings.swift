import AgentDeskCore
import AgentDeskSecurity
import Foundation

/// Observed site limits, not permission to upload. Issue permissions are checked separately by Jira.
public struct JiraAttachmentSettings: Sendable, Equatable {
    public let enabled: Bool
    public let uploadLimit: Int64
    public let context: RedactionContext
    public let cloudID: UUID
    public let observedAt: Date

    public func permitsSize(_ bytes: Int64) -> Bool {
        enabled && bytes >= 0 && bytes <= uploadLimit
    }
}

enum JiraAttachmentSettingsRead {
    static func make(resource: JiraCloudResource, tokens: JiraOAuthTokens, now: Date) throws -> URLRequest {
        var request = try JiraIssueRead.make(identifier: "1", resource: resource, tokens: tokens, now: now)
        request.url = resource.apiOrigin.appendingPathComponent("rest/api/3/attachment/meta")
        return request
    }

    static func decode(_ response: JiraHTTPResponse, context: RedactionContext,
                       cloudID: UUID, observedAt: Date) throws -> JiraAttachmentSettings {
        try JiraResponseStatus.validate(response.status)
        struct Settings: Decodable { let enabled: Bool; let uploadLimit: Int64 }
        guard response.status == 200, response.body.count <= 16_384,
              observedAt.timeIntervalSince1970.isFinite,
              let value = try? JSONDecoder().decode(Settings.self, from: response.body),
              value.uploadLimit >= 0 else { throw JiraServiceError.invalidResponse }
        // Only typed booleans/numbers escape; unexpected remote text is never retained.
        return JiraAttachmentSettings(enabled: value.enabled, uploadLimit: value.uploadLimit,
            context: context, cloudID: cloudID, observedAt: observedAt)
    }
}
