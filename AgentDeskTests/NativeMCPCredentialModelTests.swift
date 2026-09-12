#if os(macOS)
import XCTest
import AgentDeskSecurity
import AgentDeskCore
import AgentDeskRuntime
@testable import AgentDesk

@MainActor final class NativeMCPCredentialModelTests: XCTestCase {
    func testSaveClearsEntryAndWritesOnce() async throws {
        var names: [String] = [], received = Data()
        let model = NativeMCPCredentialModel { name, secret in names.append(name); received = secret.withBytes { $0 } }
        model.variable = " TOKEN "; model.value = "synthetic-value"; model.save(); model.save()
        XCTAssertEqual(model.value, "")
        try await settle(model)
        XCTAssertEqual(names, ["TOKEN"]); XCTAssertEqual(received, Data("synthetic-value".utf8)); XCTAssertTrue(model.saved)
        model.save(); XCTAssertEqual(names.count, 1)
    }
    func testEmptyInputNeverWritesAndFailureDoesNotShowRawValue() async throws {
        var calls = 0
        let model = NativeMCPCredentialModel { _, _ in calls += 1; throw NSError(domain: "synthetic-private-value", code: 1) }
        model.save(); XCTAssertEqual(calls, 0)
        model.variable = "TOKEN"; model.value = "synthetic-private-value"; model.save(); try await settle(model)
        XCTAssertEqual(calls, 1); XCTAssertFalse(model.saved); XCTAssertEqual(model.value, "")
        XCTAssertNotNil(model.error); XCTAssertFalse(model.error?.contains("synthetic-private-value") == true)
    }
    func testCancelledSaveCannotPublishLateSuccess() async throws {
        var release: CheckedContinuation<Void, Never>?
        let model = NativeMCPCredentialModel { _, _ in await withCheckedContinuation { release = $0 } }
        model.variable = "TOKEN"; model.value = "synthetic"; model.save()
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(release)
        let cancellation = Task { await model.cancel() }
        await Task.yield(); release?.resume()
        let dismissed = await cancellation.value; XCTAssertTrue(dismissed)
        try await Task.sleep(for: .milliseconds(30))
        XCTAssertFalse(model.saved); XCTAssertFalse(model.busy); XCTAssertNil(model.error); XCTAssertEqual(model.value, "")
    }
    func testCancelledRollbackFailureRemainsVisibleForRecovery() async throws {
        let reference = SecretReference(scope: try SecretScope(workspaceID: WorkspaceID(), projectID: ProjectID(), environmentID: EnvironmentID()))
        var release: CheckedContinuation<Void, Never>?
        let model = NativeMCPCredentialModel { _, _ in
            await withCheckedContinuation { release = $0 }
            throw MCPCredentialEditError.cleanupRequired(reference)
        }
        model.variable = "TOKEN"; model.value = "synthetic"; model.save()
        for _ in 0..<100 where release == nil { try await Task.sleep(for: .milliseconds(10)) }
        let cancellation = Task { await model.cancel() }
        await Task.yield(); release?.resume()
        let dismiss = await cancellation.value
        XCTAssertFalse(dismiss); XCTAssertTrue(model.needsRecovery)
        XCTAssertTrue(model.error?.contains(reference.id.uuidString) == true)
        XCTAssertFalse(model.saved); XCTAssertEqual(model.value, "")
    }
    private func settle(_ model: NativeMCPCredentialModel) async throws {
        for _ in 0..<100 where model.busy { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertFalse(model.busy)
    }
}
#endif
