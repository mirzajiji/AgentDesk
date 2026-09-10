#if os(macOS)
import AgentDeskCore
import XCTest
@testable import AgentDesk
@testable import AgentDeskRuntime

@MainActor
final class NativeRunRegistryTests: XCTestCase {
    private func open(_ fixture: RunCoordinatorTests.Fixture) async throws -> NativeRunService {
        await fixture.coordinator.shutdown()
        return try await NativeRunService.open(database: fixture.database, directory: fixture.root,
            configuration: fixture.configuration, captureRepository: false, provider: fixture.provider)
    }

    func testConfigurationWriteWaitsForActiveRunCancellationAndLeavesOtherWorkspaceOpen() async throws {
        let f = try await RunCoordinatorTests.Fixture.make(mode: .quiet)
        let other = try await RunCoordinatorTests.Fixture.make()
        let service = try await open(f), unrelated = try await open(other)
        let registry = NativeRunRegistry()
        try await registry.register(service); try await registry.register(unrelated)
        let prepared = try await service.prepare(instructions: f.instructions, configuration: f.configuration, task: "Inspect")
        let execution = try await service.start(prepared)
        await f.provider.waitForStart()
        var wrote = false
        try await registry.changeConfiguration(in: f.scope, level: .workspace) {
            let result = await execution.result()
            XCTAssertEqual(result.state, .cancelled)
            do { _ = try await service.runs(); XCTFail("Configuration write preceded shutdown") }
            catch { XCTAssertEqual(error as? RunCoordinatorError, .closed) }
            let runs = try await unrelated.runs(); XCTAssertTrue(runs.isEmpty)
            wrote = true
        }
        XCTAssertTrue(wrote)
        await unrelated.shutdown(); await f.remove(); await other.remove()
    }

    func testOverlappingConfigurationWritesAreRejectedAndFailedWriteReleasesGuard() async throws {
        enum Failure: Error { case synthetic }
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let sibling = ProjectScope(workspaceID: scope.workspaceID, projectID: ProjectID())
        let registry = NativeRunRegistry()
        do {
            try await registry.changeConfiguration(in: scope, level: .workspace) {
                do {
                    try await registry.changeConfiguration(in: sibling, level: .project) { XCTFail("Overlapping write executed") }
                    XCTFail("Overlapping write accepted")
                } catch { XCTAssertEqual(error as? CatalogError, .busy) }
                throw Failure.synthetic
            }
            XCTFail("Write failure hidden")
        } catch { XCTAssertTrue(error is Failure) }
        var wrote = false
        try await registry.changeConfiguration(in: sibling, level: .project) { wrote = true }
        XCTAssertTrue(wrote)
    }

    func testServiceCannotRegisterDuringConfigurationWrite() async throws {
        let f = try await RunCoordinatorTests.Fixture.make()
        let service = try await open(f), registry = NativeRunRegistry()
        try await registry.changeConfiguration(in: f.scope, level: .project) {
            do { try await registry.register(service); XCTFail("Service entered during configuration replacement") }
            catch { XCTAssertEqual(error as? CatalogError, .busy) }
            do { _ = try await service.runs(); XCTFail("Rejected service leaked its lease") }
            catch { XCTAssertEqual(error as? RunCoordinatorError, .closed) }
        }
        let replacement = try await open(f)
        try await registry.register(replacement)
        registry.release(service)
        await registry.stop(in: f.scope, level: .project)
        do { _ = try await replacement.runs(); XCTFail("Old release removed replacement ownership") }
        catch { XCTAssertEqual(error as? RunCoordinatorError, .closed) }
        await f.remove()
    }
}
#endif
