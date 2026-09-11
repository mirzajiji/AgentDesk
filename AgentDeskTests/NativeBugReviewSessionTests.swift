#if os(macOS)
import AgentDeskCore
import Combine
import Foundation
import XCTest
@testable import AgentDesk
@testable import AgentDeskRuntime

@MainActor
final class NativeBugReviewSessionTests: XCTestCase {
    func testContextChangeClosesReviewAndReleasesProjectOwnership() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(); await f.coordinator.shutdown()
        let catalog = try WorkspaceCatalog(container: f.root), project = try await catalog.project(f.scope)
        let services = try await WorkspaceBrowserModel(catalog: catalog, applicationRoot: f.root).executionServices(for: project)
        let context = ProjectRunContextModel(project: project, open: { services })
        await context.load(); context.selectedAgentID = f.configuration.agentID; await context.preview()
        let store = try await catalog.bugStore(in: f.scope)
        let draft = BugDraft(title: "Synthetic", sources: [.init(scope: f.scope, origin: .humanStatement, label: "Fixture", capturedAt: Date())],
            changeReason: "Reviewed", environment: f.configuration.environment.id)
        let proposal = try await store.prepare(draft, in: f.scope), incoming = try await store.publishReviewed(proposal, in: f.scope)
        let session = NativeBugReviewSession(open: { _, selected in
            try await NativeRunService.openReview(database: f.database, directory: f.root, configuration: selected.configuration)
        })
        await session.open(using: context, incomingID: incoming.id)
        XCTAssertNotNil(session.model?.review, session.error ?? "")
        let changed = expectation(description: "Changed context closes review")
        let observation = session.$error.compactMap { $0 }.filter { $0.contains("context changed") }.prefix(1).sink { _ in changed.fulfill() }
        let settings = try await services.setup.settings(), current = try XCTUnwrap(settings.project)
        var next = current.draft; next.settings.timeoutSeconds = 45
        _ = try await services.setup.save(next, at: .project, expectedRevision: current.revision)
        await fulfillment(of: [changed], timeout: 5); observation.cancel()
        XCTAssertNil(session.model); XCTAssertFalse(session.busy)
        let replacement = try await NativeRunService.openReview(database: f.database, directory: f.root, configuration: f.configuration)
        await replacement.shutdown()
        await session.close(); await f.remove()
    }
}
#endif
