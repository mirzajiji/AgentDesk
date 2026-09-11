import AgentDeskCore
import AgentDeskPlugins
import Foundation

/// Keeps current-requirement/duplicate revalidation attached to the outbound draft.
struct BugJiraComment: Sendable {
    let draft: JiraCommentDraft
    let source: BugTicketEvidenceDraft
    let configuration: JiraConnectionConfiguration

    static func prepare(_ source: BugTicketEvidenceDraft, configuration: JiraConnectionConfiguration,
                        clock: @Sendable () -> Date = { Date() }) async throws -> Self {
        try validateScope(source, configuration: configuration, at: clock())
        try await source.validate()
        try Task.checkCancellation()
        try validateScope(source, configuration: configuration, at: clock())
        let identifier = try resolve(source.ticket, site: configuration.instance)
        let draft = try JiraCommentDraft(identifier: identifier, content: source.content)
        return Self(draft: draft, source: source, configuration: configuration)
    }
    func validate(clock: @Sendable () -> Date = { Date() }) async throws {
        try Task.checkCancellation()
        try Self.validateScope(source, configuration: configuration, at: clock())
        try await source.validate()
        try Task.checkCancellation()
        try Self.validateScope(source, configuration: configuration, at: clock())
    }
    private static func validateScope(_ source: BugTicketEvidenceDraft, configuration: JiraConnectionConfiguration, at now: Date) throws {
        guard configuration.enabled, source.content.context.scope == configuration.scope,
              source.content.context.environmentID == configuration.environmentID,
              now.timeIntervalSince1970.isFinite, now < source.expiresAt else { throw BugRegistryError.invalidReview }
    }
    static func resolve(_ ticket: ExternalBugTicket, site: URL) throws -> String {
        try ticket.validate()
        // A key alone does not establish which company's Jira owns the ticket.
        guard let text = ticket.url, let url = URLComponents(string: text),
              url.scheme == "https", url.host?.lowercased() == site.host?.lowercased(),
              (url.port ?? 443) == (site.port ?? 443),
              url.percentEncodedPath == url.path else { throw BugRegistryError.invalidReview }
        let parts = url.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].isEmpty, parts[1] == "browse" else { throw BugRegistryError.invalidReview }
        let key = String(parts[2])
        _ = try ExternalBugTicket(key: key)
        guard ticket.key == nil || ticket.key == key else { throw BugRegistryError.invalidReview }
        return key
    }
}
