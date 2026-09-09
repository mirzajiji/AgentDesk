#if os(macOS)
import Foundation
import XCTest
@testable import AgentDesk
@testable import AgentDeskRuntime

@MainActor
final class CodexSettingsModelTests: XCTestCase {
    private actor FakeService: CodexDiagnosing {
        var signedIn = true
        var inspectCalls = 0
        let delay: Duration
        init(delay: Duration = .zero) { self.delay = delay }
        func inspect(executable: URL?) async throws -> CodexDiagnosticSnapshot {
            inspectCalls += 1
            if delay > .zero { try await Task.sleep(for: delay) }
            let caps = CodexCapabilities(login: true, logout: true, loginStatus: true, jsonExecution: true, stdinPrompt: true, ephemeralExecution: true, ignoreUserConfig: true)
            return CodexDiagnosticSnapshot(installation: CodexInstallation(executable: executable ?? URL(fileURLWithPath: "/synthetic/codex"), version: "0.153.4", capabilities: caps), authentication: signedIn ? .chatGPT : .signedOut, issue: nil)
        }
        func login(using installation: CodexInstallation) async throws -> CodexDiagnosticSnapshot { signedIn = true; return try await inspect(executable: installation.executable) }
        func logout(using installation: CodexInstallation) async throws -> CodexDiagnosticSnapshot { signedIn = false; return try await inspect(executable: installation.executable) }
    }
    private func waitUntilIdle(_ model: CodexSettingsModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
        XCTAssertFalse(model.isBusy)
    }
    private func root() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }

    func testAccountActionsRefreshFactsAndDisconnectPreservesCLISignIn() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeService(), store = try CodexSettingsStore(directory: directory)
        let model = CodexSettingsModel(service: service, store: store)
        XCTAssertEqual(model.status, "Not checked")
        model.refresh(); try await waitUntilIdle(model)
        XCTAssertEqual(model.status, "ChatGPT credentials found"); XCTAssertTrue(model.canLogout)
        model.logout(); try await waitUntilIdle(model)
        XCTAssertEqual(model.status, "Sign in to Codex"); XCTAssertFalse(model.canLogout)
        model.login(); try await waitUntilIdle(model)
        XCTAssertEqual(model.status, "ChatGPT credentials found")
        model.setEnabled(false)
        XCTAssertEqual(model.status, "Disconnected"); XCTAssertNil(model.snapshot)
        let signedIn = await service.signedIn; XCTAssertTrue(signedIn)
        let reopened = CodexSettingsModel(service: service, store: store)
        XCTAssertFalse(reopened.configuration.enabled)
        reopened.setEnabled(true); try await waitUntilIdle(reopened)
        XCTAssertEqual(reopened.snapshot?.authentication, .chatGPT)
    }

    func testCancelDiscardsLateResultsAndDuplicateRefreshIsCoalesced() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let service = FakeService(delay: .milliseconds(100))
        let model = CodexSettingsModel(service: service, store: try CodexSettingsStore(directory: directory))
        model.refresh(); model.refresh()
        try await Task.sleep(for: .milliseconds(20))
        model.cancel()
        try await Task.sleep(for: .milliseconds(120))
        XCTAssertNil(model.snapshot); XCTAssertFalse(model.isBusy); XCTAssertNil(model.errorMessage)
        let calls = await service.inspectCalls; XCTAssertEqual(calls, 1)
        model.refresh(); try await waitUntilIdle(model)
        XCTAssertEqual(model.snapshot?.authentication, .chatGPT)
    }

    func testExecutableSelectionPersistsLocallyAndRejectsNonFileURLs() async throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodexSettingsStore(directory: directory)
        let model = CodexSettingsModel(service: FakeService(), store: store)
        model.chooseExecutable(URL(fileURLWithPath: "/synthetic/custom codex")); try await waitUntilIdle(model)
        XCTAssertEqual(try store.load().executablePath, "/synthetic/custom codex")
        model.chooseExecutable(URL(string: "https://example.invalid/codex")!)
        XCTAssertEqual(try store.load().executablePath, "/synthetic/custom codex")
        XCTAssertNotNil(model.errorMessage)
        model.chooseExecutable(nil); try await waitUntilIdle(model)
        XCTAssertNil(try store.load().executablePath)
    }

    func testMalformedFutureAndLinkedSettingsArePreservedAndFailClosed() throws {
        let directory = root(); defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CodexSettingsStore(directory: directory), file = directory.appendingPathComponent("codex.json")
        let original = Data("{\"schemaVersion\":999,\"enabled\":true}".utf8)
        try original.write(to: file)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(CodexLocalConfiguration()))
        XCTAssertEqual(try Data(contentsOf: file), original)
        let model = CodexSettingsModel(service: FakeService(), store: store)
        XCTAssertFalse(model.canConfigure); XCTAssertNotNil(model.errorMessage)
        try FileManager.default.removeItem(at: file)
        let target = directory.appendingPathComponent("synthetic-target")
        try JSONEncoder().encode(CodexLocalConfiguration()).write(to: target)
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
        XCTAssertThrowsError(try store.load())
        try FileManager.default.removeItem(at: file)
        try FileManager.default.linkItem(at: target, to: file)
        XCTAssertThrowsError(try store.save(CodexLocalConfiguration()))
    }
}
#endif
