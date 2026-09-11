import AgentDeskCore
import AgentDeskPlugins
import AgentDeskSecurity
import Synchronization
import Foundation
import XCTest
@testable import AgentDeskRuntime

final class BugJiraCommentTests: XCTestCase {
    func testReviewIsRevalidatedAndExpiryDuringValidationFails() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let context = RedactionContext(scope: scope, environmentID: environment, runID: RunID())
        let content = try ContentRedactor(context: context).redactText("Reviewed evidence", in: context)
        let config = try JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: URL(string: "https://synthetic.atlassian.net")!, enabled: true)
        let state = Mutex((valid: true, expireDuringValidation: false, time: Date(timeIntervalSince1970: 1000)))
        let source = BugTicketEvidenceDraft(incomingID: BugID(), existingID: BugID(),
            ticket: try ExternalBugTicket(url: "https://synthetic.atlassian.net/browse/SYN-1"), content: content,
            expiresAt: Date(timeIntervalSince1970: 1100), owner: UUID(), validate: {
                try state.withLock {
                    guard $0.valid else { throw BugRegistryError.staleRevision }
                    if $0.expireDuringValidation { $0.time = Date(timeIntervalSince1970: 1100) }
                }
            })
        let comment = try await BugJiraComment.prepare(source, configuration: config, clock: { state.withLock { $0.time } })
        try await comment.validate(clock: { state.withLock { $0.time } })
        state.withLock { $0.valid = false }
        do { try await comment.validate(clock: { state.withLock { $0.time } }); XCTFail("Stale review accepted") }
        catch { XCTAssertEqual(error as? BugRegistryError, .staleRevision) }
        state.withLock { $0.valid = true; $0.expireDuringValidation = true }
        do { _ = try await BugJiraComment.prepare(source, configuration: config, clock: { state.withLock { $0.time } }); XCTFail("Expired during prepare") }
        catch { XCTAssertEqual(error as? BugRegistryError, .invalidReview) }
        state.withLock { $0.time = Date(timeIntervalSince1970: 1000) }
        do { try await comment.validate(clock: { state.withLock { $0.time } }); XCTFail("Expired during revalidation") }
        catch { XCTAssertEqual(error as? BugRegistryError, .invalidReview) }
    }

    func testTicketTargetRequiresExactConfiguredSiteAndConsistentKey() throws {
        let site = URL(string: "https://synthetic.atlassian.net")!
        XCTAssertEqual(try BugJiraComment.resolve(ExternalBugTicket(key: "SYN-1", url: "https://synthetic.atlassian.net/browse/SYN-1"), site: site), "SYN-1")
        XCTAssertEqual(try BugJiraComment.resolve(ExternalBugTicket(url: "https://synthetic.atlassian.net/browse/SYN-2"), site: site), "SYN-2")
        for ticket in [try ExternalBugTicket(key: "SYN-1"),
                       try ExternalBugTicket(key: "SYN-2", url: "https://synthetic.atlassian.net/browse/SYN-1"),
                       try ExternalBugTicket(url: "https://foreign.atlassian.net/browse/SYN-1"),
                       try ExternalBugTicket(url: "https://synthetic.atlassian.net:444/browse/SYN-1"),
                       try ExternalBugTicket(url: "https://synthetic.atlassian.net/browse/SYN-1/extra"),
                       try ExternalBugTicket(url: "https://synthetic.atlassian.net/browse/%53YN-1"),
                       try ExternalBugTicket(url: "https://synthetic.atlassian.net/not-browse/SYN-1")] {
            XCTAssertThrowsError(try BugJiraComment.resolve(ticket, site: site))
        }
    }
}
