import AgentDeskCore
import Foundation
import XCTest
@testable import AgentDeskPlugins

final class PluginConnectionLifecycleTests: XCTestCase {
    func testDisconnectClosesOwnedSessionAndDisabledConfigurationCannotConnect() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let lifecycle = PluginConnectionLifecycle(scope: scope, environmentID: environment)
        let adapter = Adapter()
        let url = try XCTUnwrap(URL(string: "https://jira.example.test"))
        try await lifecycle.configure(JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: url, enabled: true))
        try await lifecycle.connect(using: adapter)
        let connected = await lifecycle.state
        XCTAssertEqual(connected, .connected)
        let available = await lifecycle.capabilities
        XCTAssertEqual(available, [.issuesRead, .commentsRead])
        await lifecycle.disconnect()
        let disconnectedCapabilities = await lifecycle.capabilities
        XCTAssertTrue(disconnectedCapabilities.isEmpty)
        let closed = await adapter.session.closed
        XCTAssertTrue(closed)
        try await lifecycle.configure(JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: url, enabled: false))
        do {
            try await lifecycle.connect(using: adapter)
            XCTFail("Disabled connection opened")
        } catch { XCTAssertEqual(error as? PluginConnectionError, .disabled) }
        let attempts = await adapter.attempts
        XCTAssertEqual(attempts, 1)
    }

    func testCancelledConnectClosesLateSessionWithoutPublishingConnectedState() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let lifecycle = PluginConnectionLifecycle(scope: scope, environmentID: environment)
        let started = expectation(description: "Transport started")
        let adapter = DelayedAdapter(started: started)
        try await lifecycle.configure(JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: XCTUnwrap(URL(string: "https://jira.example.test")), enabled: true))
        let opening = Task { try await lifecycle.connect(using: adapter) }
        await fulfillment(of: [started], timeout: 2)
        opening.cancel()
        await adapter.finish()
        do { try await opening.value; XCTFail("Cancelled connection succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let state = await lifecycle.state
        let closed = await adapter.session.closed
        XCTAssertEqual(state, .disconnected)
        XCTAssertTrue(closed)
    }

    func testReplacementWaitsForAlreadyRunningDisconnectCleanup() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let lifecycle = PluginConnectionLifecycle(scope: scope, environmentID: environment)
        let closing = expectation(description: "Close started")
        let session = ClosingSession(started: closing)
        try await lifecycle.configure(JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: XCTUnwrap(URL(string: "https://jira.example.test")), enabled: true))
        try await lifecycle.connect(using: FixedAdapter(session: session))
        let disconnect = Task { await lifecycle.disconnect() }
        await fulfillment(of: [closing], timeout: 2)
        let replacement = Adapter()
        let reconnect = Task { try await lifecycle.connect(using: replacement) }
        // Give the overlapping call an opportunity to reach its cleanup barrier.
        try await Task.sleep(for: .milliseconds(50))
        let earlyAttempts = await replacement.attempts
        XCTAssertEqual(earlyAttempts, 0)
        await session.finish()
        await disconnect.value
        try await reconnect.value
        let attempts = await replacement.attempts
        let state = await lifecycle.state
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(state, .connected)
        await lifecycle.disconnect()
    }

    func testTimeoutCancelsTransportAndLeavesErrorState() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let lifecycle = PluginConnectionLifecycle(scope: scope, environmentID: environment)
        try await lifecycle.configure(JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: XCTUnwrap(URL(string: "https://jira.example.test")), enabled: true))
        do {
            try await lifecycle.connect(using: SleepingAdapter(), timeout: .milliseconds(20))
            XCTFail("Timed out connection succeeded")
        } catch { XCTAssertEqual(error as? PluginConnectionError, .timedOut) }
        let state = await lifecycle.state
        XCTAssertEqual(state, .error)
        await lifecycle.disconnect()
    }

    func testAuthenticationFailureAndInvalidTimeoutKeepDistinctStates() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let lifecycle = PluginConnectionLifecycle(scope: scope, environmentID: environment)
        try await lifecycle.configure(JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: XCTUnwrap(URL(string: "https://jira.example.test")), enabled: true))
        do {
            try await lifecycle.connect(using: ExpiredAdapter())
            XCTFail("Expired authentication connected")
        } catch { XCTAssertEqual(error as? PluginConnectionError, .authenticationExpired) }
        let expired = await lifecycle.state
        XCTAssertEqual(expired, .authenticationExpired)
        let adapter = Adapter()
        for timeout: Duration in [.zero, .seconds(-1), .seconds(121)] {
            do {
                try await lifecycle.connect(using: adapter, timeout: timeout)
                XCTFail("Invalid timeout accepted")
            } catch { XCTAssertEqual(error as? PluginConnectionError, .invalidTimeout) }
        }
        let state = await lifecycle.state
        let attempts = await adapter.attempts
        XCTAssertEqual(state, .authenticationExpired)
        XCTAssertEqual(attempts, 0)
    }

    func testDisableDuringConnectRejectsLateCompletion() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let lifecycle = PluginConnectionLifecycle(scope: scope, environmentID: environment)
        let url = try XCTUnwrap(URL(string: "https://jira.example.test"))
        try await lifecycle.configure(JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: url, enabled: true))
        let started = expectation(description: "Transport started")
        let adapter = DelayedAdapter(started: started)
        let opening = Task { try await lifecycle.connect(using: adapter) }
        await fulfillment(of: [started], timeout: 2)
        let disable = Task {
            try await lifecycle.configure(JiraConnectionConfiguration(scope: scope, environmentID: environment,
                instance: url, enabled: false))
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await lifecycle.state != .disabled, ContinuousClock.now < deadline { await Task.yield() }
        let disablingState = await lifecycle.state
        XCTAssertEqual(disablingState, .disabled)
        await adapter.finish()
        try await disable.value
        do { try await opening.value; XCTFail("Stale connection published") }
        catch { XCTAssertTrue(error is CancellationError) }
        let finalState = await lifecycle.state
        let capabilities = await lifecycle.capabilities
        let closed = await adapter.session.closed
        XCTAssertEqual(finalState, .disabled)
        XCTAssertTrue(capabilities.isEmpty)
        XCTAssertTrue(closed)
    }

    func testForeignConfigurationDoesNotReplaceActiveConnection() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let lifecycle = PluginConnectionLifecycle(scope: scope, environmentID: environment)
        let adapter = Adapter()
        let url = try XCTUnwrap(URL(string: "https://jira.example.test"))
        try await lifecycle.configure(JiraConnectionConfiguration(scope: scope, environmentID: environment,
            instance: url, enabled: true))
        try await lifecycle.connect(using: adapter)
        do {
            try await lifecycle.configure(JiraConnectionConfiguration(scope: scope, environmentID: EnvironmentID(), instance: url))
            XCTFail("Foreign configuration accepted")
        } catch { XCTAssertEqual(error as? PluginConnectionError, .scopeMismatch) }
        let state = await lifecycle.state
        let closed = await adapter.session.closed
        XCTAssertEqual(state, .connected); XCTAssertFalse(closed)
        await lifecycle.disconnect()
    }
}

private actor Session: PluginConnectionSession {
    let capabilities: Set<PluginCapability> = [.issuesRead, .commentsRead]
    var closed = false
    func close() { closed = true }
}
private actor Adapter: JiraConnectionAdapter {
    let session = Session()
    var attempts = 0
    func connect(_ configuration: JiraConnectionConfiguration) -> any PluginConnectionSession {
        attempts += 1
        return session
    }
}

private actor DelayedAdapter: JiraConnectionAdapter {
    let session = Session()
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<any PluginConnectionSession, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func connect(_ configuration: JiraConnectionConfiguration) async -> any PluginConnectionSession {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func finish() {
        continuation?.resume(returning: session)
        continuation = nil
    }
}

private struct FixedAdapter: JiraConnectionAdapter {
    let session: any PluginConnectionSession
    func connect(_ configuration: JiraConnectionConfiguration) async throws -> any PluginConnectionSession { session }
}
private actor ClosingSession: PluginConnectionSession {
    let capabilities: Set<PluginCapability> = []
    let started: XCTestExpectation
    private var continuation: CheckedContinuation<Void, Never>?
    private var closed = false
    init(started: XCTestExpectation) { self.started = started }
    func close() async {
        guard !closed else { return }
        closed = true
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }
    func finish() { continuation?.resume(); continuation = nil }
}

private struct SleepingAdapter: JiraConnectionAdapter {
    func connect(_ configuration: JiraConnectionConfiguration) async throws -> any PluginConnectionSession {
        try await Task.sleep(for: .seconds(60))
        return Session()
    }
}

private struct ExpiredAdapter: JiraConnectionAdapter {
    func connect(_ configuration: JiraConnectionConfiguration) async throws -> any PluginConnectionSession {
        throw PluginConnectionError.authenticationExpired
    }
}
