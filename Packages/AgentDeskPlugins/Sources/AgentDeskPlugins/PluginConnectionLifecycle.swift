import AgentDeskCore
import Foundation

public enum PluginConnectionState: String, Sendable {
    case disabled, notConfigured, connecting, connected, authenticationExpired, error, disconnected
}

public enum PluginConnectionError: Error, Equatable, Sendable {
    case scopeMismatch, disabled, notConfigured, authenticationExpired, unavailable, superseded, invalidTimeout, timedOut
}

/// A transport session owns its resources. Close must be idempotent and finish cleanup.
public protocol PluginConnectionSession: Sendable {
    var capabilities: Set<PluginCapability> { get }
    func close() async
}

/// Implementations must propagate cancellation and release partial resources on failure.
public protocol JiraConnectionAdapter: Sendable {
    func connect(_ configuration: JiraConnectionConfiguration) async throws -> any PluginConnectionSession
}

/// Administrative lifecycle only. Capability execution is separately policy-authorized.
public actor PluginConnectionLifecycle {
    public nonisolated let scope: ProjectScope
    public nonisolated let environmentID: EnvironmentID
    public private(set) var state: PluginConnectionState = .notConfigured
    public private(set) var capabilities: Set<PluginCapability> = []
    private var configuration: JiraConnectionConfiguration?
    private var generation = UUID()
    private var pending: Task<any PluginConnectionSession, any Error>?
    private var session: (any PluginConnectionSession)?
    private var cleanup: Task<Void, Never>?

    public init(scope: ProjectScope, environmentID: EnvironmentID) {
        self.scope = scope; self.environmentID = environmentID
    }

    public func configure(_ value: JiraConnectionConfiguration) async throws {
        guard value.scope == scope, value.environmentID == environmentID else {
            throw PluginConnectionError.scopeMismatch
        }
        let token = UUID(); generation = token
        configuration = value
        state = value.enabled ? .disconnected : .disabled
        await releaseResources()
        guard generation == token else { throw PluginConnectionError.superseded }
    }

    public func connect(using adapter: any JiraConnectionAdapter, timeout: Duration = .seconds(30)) async throws {
        try Task.checkCancellation()
        guard timeout > .zero, timeout <= .seconds(120) else { throw PluginConnectionError.invalidTimeout }
        guard let configuration else { throw PluginConnectionError.notConfigured }
        guard configuration.enabled else { throw PluginConnectionError.disabled }
        let token = UUID(); generation = token
        state = .connecting
        await releaseResources()
        guard generation == token else { throw PluginConnectionError.superseded }
        do { try Task.checkCancellation() } catch { state = .disconnected; throw error }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        let task = Task { try await adapter.connect(configuration) }
        pending = task
        let timer = Task {
            do { try await ContinuousClock().sleep(until: deadline); task.cancel() }
            catch { /* Successful connection or caller cancellation stopped the timer. */ }
        }
        defer { timer.cancel() }
        do {
            let connected = try await withTaskCancellationHandler {
                try await task.value
            } onCancel: { task.cancel() }
            guard generation == token, !Task.isCancelled else {
                await connected.close()
                throw CancellationError()
            }
            guard ContinuousClock.now < deadline else {
                await connected.close()
                throw PluginConnectionError.timedOut
            }
            pending = nil; session = connected; capabilities = connected.capabilities; state = .connected
        } catch {
            let failure: any Error = !Task.isCancelled && ContinuousClock.now >= deadline
                ? PluginConnectionError.timedOut : error
            if generation == token {
                pending = nil
                if failure is CancellationError { state = .disconnected }
                else if failure as? PluginConnectionError == .authenticationExpired { state = .authenticationExpired }
                else { state = .error }
            }
            throw failure
        }
    }

    public func disconnect() async {
        generation = UUID()
        state = configuration?.enabled == false ? .disabled : .disconnected
        await releaseResources()
    }

    private func releaseResources() async {
        capabilities = []
        let opening = pending; pending = nil
        let current = session; session = nil
        opening?.cancel()
        // Actor reentrancy must not let a later replacement bypass an earlier close.
        let previous = cleanup
        let next = Task {
            await previous?.value
            if let opening, let late = try? await opening.value { await late.close() }
            await current?.close()
        }
        cleanup = next
        await next.value
    }
}
