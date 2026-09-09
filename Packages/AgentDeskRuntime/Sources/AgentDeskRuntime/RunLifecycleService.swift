import AgentDeskCore
import AgentDeskPersistence
import Foundation

public enum RunLifecycleError: Error, Equatable, Sendable {
    case scopeMismatch, missingRun, invalidTransition, staleSequence, invalidCursor, replayRequired, busy, closed, invalidTimestamp
}

public struct RunEventSubscription: Sendable {
    public let events: AsyncThrowingStream<StoredRunEvent, any Error>
    private let finish: @Sendable () -> Void
    init(events: AsyncThrowingStream<StoredRunEvent, any Error>, finish: @escaping @Sendable () -> Void) {
        self.events = events; self.finish = finish
    }
    /// Call when abandoning observation without cancelling the consuming task.
    public func cancel() { finish() }
}

/// One local execution authority per project. Remote/UI commands require an outer policy boundary.
/// Accepted states are committed before delivery. No prompts or provider output enter this stream.
public actor RunLifecycleService {
    public nonisolated let scope: ProjectScope
    private let store: OperationalStore
    private var inFlight: Set<RunID> = []
    private var closed = false
    private struct Subscriber: Sendable {
        let continuation: AsyncThrowingStream<StoredRunEvent, any Error>.Continuation
        var sequence: Int64
    }
    private var subscribers: [RunID: [UUID: Subscriber]] = [:]
    var subscriberCount: Int { subscribers.values.reduce(0) { $0 + $1.count } }

    public init(store: OperationalStore, scope: ProjectScope) throws {
        guard store.workspaceID == scope.workspaceID else { throw RunLifecycleError.scopeMismatch }
        self.store = store; self.scope = scope
    }

    deinit {
        for observers in subscribers.values {
            for subscriber in observers.values { subscriber.continuation.finish(throwing: RunLifecycleError.closed) }
        }
    }

    public func createRun(in requested: ProjectScope, id: RunID = RunID(), at date: Date = Date()) async throws -> StoredRun {
        try begin(id, requested: requested)
        defer { inFlight.remove(id) }
        let run = try await store.createRun(in: scope, id: id, at: date)
        publish(StoredRunEvent(runID: id, scope: scope, sequence: 1, state: .queued, recordedAt: run.createdAt))
        return run
    }

    public func run(_ id: RunID, in requested: ProjectScope) async throws -> StoredRun? {
        try validate(requested)
        return try await store.run(id, in: scope)
    }

    public func transition(_ id: RunID, in requested: ProjectScope, to next: RunState,
                           expectedSequence: Int64, at date: Date = Date()) async throws -> StoredRunEvent {
        try begin(id, requested: requested)
        defer { inFlight.remove(id) }
        guard let run = try await store.run(id, in: scope) else { throw RunLifecycleError.missingRun }
        guard run.sequence == expectedSequence else { throw RunLifecycleError.staleSequence }
        guard run.state.canTransition(to: next) else { throw RunLifecycleError.invalidTransition }
        let previous = try await store.events(for: id, in: scope, after: run.sequence - 1, limit: 1)
        guard let last = previous.last, date.timeIntervalSince1970.isFinite, date >= last.recordedAt else {
            throw RunLifecycleError.invalidTimestamp
        }
        try validate(requested)
        let event = try await store.recordState(next, for: id, in: scope, expectedSequence: expectedSequence, at: date)
        publish(event)
        return event
    }

    public func history(for id: RunID, in requested: ProjectScope, after sequence: Int64 = 0,
                        limit: Int = 256) async throws -> [StoredRunEvent] {
        try validate(requested)
        guard try await store.run(id, in: scope) != nil else { throw RunLifecycleError.missingRun }
        return try await store.events(for: id, in: scope, after: sequence, limit: limit)
    }

    /// Replay and registration share the per-run operation gate, so local transitions cannot fall into a gap.
    /// Large backlogs require paged history or a snapshot before subscribing. Overflow is an explicit error.
    public func subscribe(to id: RunID, in requested: ProjectScope, after sequence: Int64 = 0,
                          capacity: Int = 256) async throws -> RunEventSubscription {
        try begin(id, requested: requested)
        defer { inFlight.remove(id) }
        guard sequence >= 0, (1...999).contains(capacity) else { throw RunLifecycleError.invalidCursor }
        guard let run = try await store.run(id, in: scope) else { throw RunLifecycleError.missingRun }
        guard sequence <= run.sequence else { throw RunLifecycleError.invalidCursor }
        let replay = try await store.events(for: id, in: scope, after: sequence, limit: capacity + 1)
        guard replay.count <= capacity else { throw RunLifecycleError.replayRequired }
        var cursor = sequence
        for event in replay {
            guard event.sequence == cursor + 1 else { throw RunLifecycleError.replayRequired }
            cursor = event.sequence
        }
        guard cursor == run.sequence else { throw RunLifecycleError.replayRequired }
        try validate(requested)
        let (events, continuation) = AsyncThrowingStream<StoredRunEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(capacity))
        let token = UUID()
        continuation.onTermination = { [weak self] _ in Task { await self?.remove(id, token: token) } }
        for event in replay { continuation.yield(event) }
        if run.state.isTerminal { continuation.finish() }
        else { subscribers[id, default: [:]][token] = Subscriber(continuation: continuation, sequence: cursor) }
        return RunEventSubscription(events: events, finish: { continuation.finish() })
    }

    public func shutdown() {
        closed = true
        let current = subscribers; subscribers.removeAll()
        for observers in current.values {
            for subscriber in observers.values { subscriber.continuation.finish(throwing: RunLifecycleError.closed) }
        }
    }

    private func begin(_ id: RunID, requested: ProjectScope) throws {
        try validate(requested)
        guard inFlight.insert(id).inserted else { throw RunLifecycleError.busy }
    }

    private func validate(_ requested: ProjectScope) throws {
        try Task.checkCancellation()
        guard requested == scope else { throw RunLifecycleError.scopeMismatch }
        guard !closed else { throw RunLifecycleError.closed }
    }

    private func publish(_ event: StoredRunEvent) {
        for (token, var subscriber) in subscribers[event.runID] ?? [:] {
            guard event.sequence == subscriber.sequence + 1 else {
                subscriber.continuation.finish(throwing: RunLifecycleError.replayRequired)
                remove(event.runID, token: token); continue
            }
            switch subscriber.continuation.yield(event) {
            case .enqueued:
                subscriber.sequence = event.sequence
                subscribers[event.runID]?[token] = subscriber
                if event.state.isTerminal { subscriber.continuation.finish(); remove(event.runID, token: token) }
            case .dropped:
                subscriber.continuation.finish(throwing: RunLifecycleError.replayRequired)
                remove(event.runID, token: token)
            case .terminated:
                remove(event.runID, token: token)
            @unknown default:
                subscriber.continuation.finish(throwing: RunLifecycleError.replayRequired)
                remove(event.runID, token: token)
            }
        }
    }

    private func remove(_ id: RunID, token: UUID) {
        subscribers[id]?.removeValue(forKey: token)
        if subscribers[id]?.isEmpty == true { subscribers.removeValue(forKey: id) }
    }
}
