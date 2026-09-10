import AgentDeskCore
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class BugRunBindingTests: XCTestCase {
    struct ChangingRepository: RunRepositoryCapturing {
        let context: RedactionContext
        let resource: ExecutionResource
        let redactor: ContentRedactor
        let store: ProjectBugStore
        let record: BugRecord
        func captureBaseline() async throws -> RepositoryEvidence {
            var draft = record.content; draft.actualBehavior = "Changed during baseline"
            let proposal = try await store.prepare(draft, id: record.id, expectedRevision: record.revision, in: context.scope)
            _ = try await store.publishReviewed(proposal, in: context.scope)
            return try await captureChanges()
        }
        func captureChanges() async throws -> RepositoryEvidence {
            .init(snapshot: try redactor.redactJSON("{}", in: context), diff: try redactor.redactText("Synthetic", in: context))
        }
    }
    func testChangedRegistryDuringBaselinePreventsProviderDispatch() async throws {
        let f = try await RunCoordinatorTests.Fixture.make()
        let catalog = try WorkspaceCatalog(container: f.root), store = try await catalog.bugStore(in: f.scope)
        let draft = BugDraft(title: "Synthetic", sources: [.init(scope: f.scope, origin: .humanStatement, label: "Synthetic", capturedAt: Date())],
            changeReason: "Reviewed", environment: f.configuration.environment.id)
        let proposal = try await store.prepare(draft, in: f.scope), record = try await store.publishReviewed(proposal, in: f.scope)
        let snapshot = try await store.comparisonSnapshot(in: f.scope, environment: f.configuration.environment.id)
        let prepared = try await f.coordinator.prepare(instructions: f.instructions, configuration: f.configuration,
            task: "Review", requesterID: f.requester.id, redactor: { try ContentRedactor(context: $0) },
            bugReview: { redactor in
                PreparedBugContext(content: try redactor.redactJSON("{}", in: redactor.context), validate: { try await store.validate(snapshot, in: f.scope) })
            }, repository: { context, redactor in
                ChangingRepository(context: context, resource: f.provider.resource, redactor: redactor, store: store, record: record)
            })
        let execution = try await f.coordinator.start(prepared.token), outcome = await execution.result()
        XCTAssertEqual(outcome.state, .failed); XCTAssertEqual(outcome.failure, .invalidPreparation)
        let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty)
        await f.remove()
    }
    func testDeniedPolicyDoesNotCollectBugContext() async throws {
        for (run, read) in [(PolicyDisposition.deny, PolicyDisposition.allow), (.allow, .deny)] {
            let f = try await RunCoordinatorTests.Fixture.make(disposition: run, readDisposition: read)
            let called = Mutex(false)
            do {
                _ = try await f.coordinator.prepare(instructions: f.instructions, configuration: f.configuration,
                    task: "Review", requesterID: f.requester.id, redactor: { try ContentRedactor(context: $0) }, bugReview: { _ in
                        called.withLock { $0 = true }; throw BugRegistryError.invalidReview
                    })
                XCTFail("Denied preparation accepted")
            } catch { XCTAssertTrue(error is AuthorizationError) }
            XCTAssertFalse(called.withLock { $0 }); await f.remove()
        }
    }
}
