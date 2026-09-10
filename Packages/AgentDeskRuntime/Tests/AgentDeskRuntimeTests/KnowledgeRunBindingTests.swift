import AgentDeskCore
import AgentDeskPersistence
import AgentDeskSecurity
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class KnowledgeRunBindingTests: XCTestCase {
    typealias Fixture = RunCoordinatorTests.Fixture
    func selection() throws -> AgentKnowledgeSelection { try .init(paths: .init(include: ["qa/**"])) }
    func seed(_ f: Fixture) async throws -> (KnowledgeContextService, ProjectMemoryStore, MemoryRecord) {
        let catalog = try WorkspaceCatalog(container: f.root), environment = f.configuration.environment.id
        let memory = try await catalog.memoryStore(in: f.scope), requirements = try await catalog.requirementStore(in: f.scope)
        let draft = MemoryDraft(kind: .confirmed, topic: .testExpectation, title: "Synthetic selected behavior",
            body: "Refund requires review. password: synthetic-knowledge-secret-4389",
            sources: [.init(scope: f.scope, origin: .humanStatement, label: "Synthetic fixture", capturedAt: Date())],
            changeReason: "Reviewed", knowledgePath: KnowledgePath(rawValue: "qa/refund")!)
        let proposal = try await memory.prepare(draft, in: f.scope)
        let record = try await memory.publishReviewed(proposal, in: f.scope)
        let index = try KnowledgeSearchIndex(database: f.database, scope: f.scope, environment: environment)
        _ = try await index.rebuild(memory: memory, requirements: requirements,
            redactor: ContentRedactor(context: .init(scope: f.scope, environmentID: environment, runID: RunID())))
        return (try KnowledgeContextService(memory: memory, requirements: requirements, environment: environment, search: index), memory, record)
    }
    func prepare(_ f: Fixture, service: KnowledgeContextService) async throws -> PreparedRun {
        let selection = try XCTUnwrap(f.configuration.knowledge)
        return try await f.coordinator.prepare(instructions: f.instructions, configuration: f.configuration,
            task: "Inspect selected behavior", requesterID: f.requester.id,
            redactor: { try ContentRedactor(context: $0) }, knowledge: { try await service.prepare(selection, redactor: $0) })
    }
    func testExactRedactedContextIsReviewedPersistedAndDispatched() async throws {
        let f = try await Fixture.make(disposition: .approval, knowledge: selection())
        let (service, _, record) = try await seed(f)
        let prepared = try await prepare(f, service: service), context = try XCTUnwrap(prepared.knowledgeSnapshot)
        XCTAssertTrue(context.contains(record.id.rawValue)); XCTAssertFalse(context.contains("synthetic-knowledge-secret-4389"))
        let before = await f.provider.requests; XCTAssertTrue(before.isEmpty)
        let approval = try XCTUnwrap(prepared.approval)
        _ = try await f.gate.review(approval.id, expectedAction: prepared.action, requesterID: f.requester.id,
            reviewerID: f.reviewer.id, approve: true, expectedSequence: approval.sequence)
        let execution = try await f.coordinator.start(prepared.token), outcome = await execution.result()
        XCTAssertEqual(outcome.state, .completed)
        let requests = await f.provider.requests, request = try XCTUnwrap(requests.first)
        XCTAssertTrue(request.task.hasSuffix(context))
        let evidence = try f.evidence(prepared), records = try await evidence.records(limit: 1)
        let stored = try await evidence.artifact(XCTUnwrap(records.first?.id)), snapshot = try XCTUnwrap(stored)
        XCTAssertEqual(try ActionFingerprint(bytes: Data(snapshot.text.utf8)), prepared.action.payload)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(snapshot.text.utf8)) as? [String: Any])
        XCTAssertEqual(object["task"] as? String, request.task)
        XCTAssertFalse(snapshot.text.contains("synthetic-knowledge-secret-4389"))
        await f.remove()
    }

    func testDeniedRunOrReadDoesNotInvokeKnowledgeReader() async throws {
        for (run, read) in [(PolicyDisposition.deny, PolicyDisposition.allow), (.allow, .deny)] {
            let f = try await Fixture.make(disposition: run, knowledge: selection(), readDisposition: read)
            let called = Mutex(false)
            do {
                _ = try await f.coordinator.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect",
                    requesterID: f.requester.id, redactor: { try ContentRedactor(context: $0) }, knowledge: { _ in
                        called.withLock { $0 = true }; throw KnowledgeContextError.invalidCandidate
                    })
                XCTFail("Denied operation prepared")
            } catch { XCTAssertTrue(error is AuthorizationError) }
            XCTAssertFalse(called.withLock { $0 })
            let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty)
            await f.remove()
        }
    }

    func testChangedSourcePreventsApprovedDispatch() async throws {
        let f = try await Fixture.make(disposition: .approval, knowledge: selection())
        let (service, memory, record) = try await seed(f)
        let prepared = try await prepare(f, service: service), approval = try XCTUnwrap(prepared.approval)
        _ = try await f.gate.review(approval.id, expectedAction: prepared.action, requesterID: f.requester.id,
            reviewerID: f.reviewer.id, approve: true, expectedSequence: approval.sequence)
        var draft = record.content; draft.body = "Different current behavior"
        let update = try await memory.prepare(draft, id: record.id, expectedRevision: 1, in: f.scope)
        _ = try await memory.publishReviewed(update, in: f.scope)
        do { _ = try await f.coordinator.start(prepared.token); XCTFail("Stale source dispatched") }
        catch { XCTAssertEqual(error as? KnowledgeContextError, .staleSources) }
        let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty)
        await f.remove()
    }

    struct ChangingRepository: RunRepositoryCapturing {
        let context: RedactionContext
        let resource: ExecutionResource
        let redactor: ContentRedactor
        let memory: ProjectMemoryStore
        let record: MemoryRecord
        func captureBaseline() async throws -> RepositoryEvidence {
            var draft = record.content; draft.body = "Changed while collecting baseline"
            let proposal = try await memory.prepare(draft, id: record.id, expectedRevision: 1, in: context.scope)
            _ = try await memory.publishReviewed(proposal, in: context.scope)
            return try await captureChanges()
        }
        func captureChanges() async throws -> RepositoryEvidence {
            RepositoryEvidence(snapshot: try redactor.redactJSON("{}", in: context), diff: try redactor.redactText("Synthetic baseline", in: context))
        }
    }
    func testSourceChangeDuringBaselineFailsPreparationBeforeProviderStarts() async throws {
        let selection = try selection(), f = try await Fixture.make(knowledge: selection)
        let (service, memory, record) = try await seed(f)
        let prepared = try await f.coordinator.prepare(instructions: f.instructions, configuration: f.configuration,
            task: "Inspect", requesterID: f.requester.id, redactor: { try ContentRedactor(context: $0) },
            knowledge: { try await service.prepare(selection, redactor: $0) }, repository: { context, redactor in
                ChangingRepository(context: context, resource: f.provider.resource, redactor: redactor, memory: memory, record: record)
            })
        let execution = try await f.coordinator.start(prepared.token), outcome = await execution.result()
        XCTAssertEqual(outcome.state, .failed); XCTAssertEqual(outcome.failure, .invalidPreparation)
        let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty)
        await f.remove()
    }

    func testEnabledKnowledgeCannotSilentlyRunWithoutItsReader() async throws {
        let f = try await Fixture.make(knowledge: selection())
        do { _ = try await f.prepare(); XCTFail("Knowledge omitted") }
        catch { XCTAssertEqual(error as? RunCoordinatorError, .invalidPreparation) }
        let requests = await f.provider.requests; XCTAssertTrue(requests.isEmpty)
        await f.remove()
    }

    #if os(macOS)
    func testNativeServiceBuildsIndexAndExposesExactKnowledgeSnapshot() async throws {
        let f = try await Fixture.make(knowledge: selection())
        let (_, _, record) = try await seed(f)
        await f.coordinator.shutdown()
        let service = try await NativeRunService.open(database: f.database, directory: f.root,
            configuration: f.configuration, captureRepository: false, provider: f.provider)
        let catalog = try WorkspaceCatalog(container: f.root)
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration,
            task: "Inspect", knowledgeCatalog: catalog)
        XCTAssertTrue(prepared.knowledgeSnapshot?.contains(record.id.rawValue) == true)
        let execution = try await service.start(prepared), outcome = await execution.result()
        XCTAssertEqual(outcome.state, .completed)
        await service.shutdown(); await f.remove()
    }
    #endif
}
