#if os(macOS)
import AgentDeskCore
import AgentDeskPersistence
import Combine
import Foundation
import Synchronization
import XCTest
@testable import AgentDesk
@testable import AgentDeskRuntime

@MainActor
final class NativeRunSessionTests: XCTestCase {
    func testSuccessfulExecutionPublishesConfirmedResultAndOpenEndedProgress() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(disposition: .approval)
        await f.coordinator.shutdown()
        let model = try await contextModel(f), session = session(f)
        await session.prepare(using: model, task: "Inspect")
        let finished = expectation(description: "Confirmed run completion")
        let observation = session.$phase.filter { $0 == .finished }.prefix(1).sink { _ in finished.fulfill() }
        await session.start()
        await fulfillment(of: [finished], timeout: 5)
        observation.cancel()
        XCTAssertEqual(session.outcome?.state, .completed)
        XCTAssertEqual(session.run?.state, .completed)
        XCTAssertNotNil(session.outcome?.finalArtifactID)
        XCTAssertEqual(session.progress?.mode, .openEnded)
        XCTAssertNil(session.progress?.overallProgress)
        let requests = await f.provider.requests; XCTAssertEqual(requests.count, 1)
        await session.close(); await f.remove()
    }

    func testExternalConfigurationChangeStopsActiveSession() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(mode: .quiet, disposition: .approval)
        await f.coordinator.shutdown()
        let model = try await contextModel(f), session = session(f)
        await session.prepare(using: model, task: "Inspect"); await session.start()
        await f.provider.waitForStart()
        let stopped = expectation(description: "Changed configuration stops execution")
        let observation = session.$errorMessage.compactMap { $0 }.filter { $0.contains("sources changed") }
            .prefix(1).sink { _ in stopped.fulfill() }
        let setup = try XCTUnwrap(model.services?.setup)
        let settings = try await setup.settings(), current = try XCTUnwrap(settings.project)
        var changed = current.draft; changed.settings.timeoutSeconds = 45
        _ = try await setup.save(changed, at: .project, expectedRevision: current.revision)
        await fulfillment(of: [stopped], timeout: 5)
        observation.cancel()
        XCTAssertEqual(session.phase, .idle); XCTAssertNil(session.service); XCTAssertNil(session.prepared)
        XCTAssertGreaterThan(f.provider.cancellations.withLock { $0 }, 0)
        await session.close(); await f.remove()
    }
    private func contextModel(_ f: RunCoordinatorTests.Fixture) async throws -> ProjectRunContextModel {
        let catalog = try WorkspaceCatalog(container: f.root)
        let project = try await catalog.project(f.scope)
        let services = try await WorkspaceBrowserModel(catalog: catalog, applicationRoot: f.root).executionServices(for: project)
        let model = ProjectRunContextModel(project: project, open: { services })
        await model.load(); model.selectedAgentID = f.configuration.agentID; await model.preview()
        XCTAssertNotNil(model.presentation)
        return model
    }
    private func session(_ f: RunCoordinatorTests.Fixture) -> NativeRunSession {
        NativeRunSession(registry: NativeRunRegistry(), open: { _, context in
            try await NativeRunService.open(database: f.database, directory: f.root,
                configuration: context.configuration, captureRepository: false, provider: f.provider)
        })
    }

    func testPreparedInputIsRedactedAndRejectionNeverStartsProvider() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(disposition: .approval)
        await f.coordinator.shutdown()
        let model = try await contextModel(f), session = session(f)
        await session.prepare(using: model, task: "Inspect\npassword=synthetic-console-secret")
        XCTAssertEqual(session.phase, .prepared)
        XCTAssertNotNil(session.prepared?.approval)
        let input = try XCTUnwrap(session.inputSnapshot)
        XCTAssertFalse(input.contains("synthetic-console-secret"))
        XCTAssertTrue(input.contains("[REDACTED]"))
        let before = await f.provider.requests; XCTAssertTrue(before.isEmpty)
        await session.reject()
        XCTAssertEqual(session.phase, .finished)
        let after = await f.provider.requests; XCTAssertTrue(after.isEmpty)
        XCTAssertTrue(session.outcome?.state?.isTerminal == true)
        await session.close(); XCTAssertEqual(session.phase, .idle); XCTAssertNil(session.service)
        await f.remove()
    }

    func testClosingActiveSessionCancelsAndReleasesService() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(mode: .quiet, disposition: .approval)
        await f.coordinator.shutdown()
        let model = try await contextModel(f), session = session(f)
        await session.prepare(using: model, task: "Inspect")
        let service = try XCTUnwrap(session.service)
        await session.start(); await f.provider.waitForStart()
        XCTAssertEqual(session.phase, .running)
        async let first: Void = session.close()
        async let second: Void = session.close()
        _ = await (first, second)
        XCTAssertEqual(session.phase, .idle); XCTAssertFalse(session.hasPendingWork)
        XCTAssertNil(session.prepared); XCTAssertNil(session.service)
        do { _ = try await service.runs(); XCTFail("Closed console retained active service") }
        catch { XCTAssertEqual(error as? RunCoordinatorError, .closed) }
        XCTAssertGreaterThan(f.provider.cancellations.withLock { $0 }, 0)
        await f.remove()
    }

    func testMissingReviewedContextDoesNotOpenProviderService() async throws {
        let f = try await RunCoordinatorTests.Fixture.make()
        await f.coordinator.shutdown()
        let model = try await contextModel(f)
        model.invalidate()
        var opened = false
        let session = NativeRunSession(registry: NativeRunRegistry(), open: { _, _ in
            opened = true; throw NativeConsoleError.codexUnavailable
        })
        await session.prepare(using: model, task: "Inspect")
        XCTAssertFalse(opened); XCTAssertEqual(session.phase, .idle)
        XCTAssertNotNil(session.errorMessage); XCTAssertNil(session.prepared)
        await session.close(); await f.remove()
    }
}
#endif
