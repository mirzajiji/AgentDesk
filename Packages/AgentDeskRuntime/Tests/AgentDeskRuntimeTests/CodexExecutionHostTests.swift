#if os(macOS)
import AgentDeskCore
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskRuntime

private actor LoopbackExecutionConnection: CodexExecutionConnection {
    let session: CodexExecutionHostSession
    var closed = false
    init(_ session: CodexExecutionHostSession) { self.session = session }
    func send(_ data: Data) async throws -> Data {
        guard !closed else { throw ExecutionProviderError.unavailable }
        return await withTaskCancellationHandler { await session.perform(data) }
            onCancel: { [session] in Task { await session.invalidate() } }
    }
    func close() async { closed = true; await session.invalidate() }
}

private actor HostCancellationSignal {
    private var finished = false
    private var waiter: CheckedContinuation<Void, Never>?
    func mark() { finished = true; waiter?.resume(); waiter = nil }
    func wait() async { if !finished { await withCheckedContinuation { waiter = $0 } } }
}
private struct BurstExecutionProvider: ExecutionProvider {
    let resource: ExecutionResource
    let signal: HostCancellationSignal
    func start(_ request: ExecutionRequest) async throws -> ProviderExecution {
        let (stream, continuation) = AsyncThrowingStream<ExecutionProviderEvent, any Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        continuation.yield(.init(identity: request.identity, sequence: 1, payload: .started))
        for index in 0..<70 {
            continuation.yield(.init(identity: request.identity, sequence: Int64(index + 2), payload: .message(id: "message-\(index)", text: "synthetic")))
        }
        continuation.yield(.init(identity: request.identity, sequence: 72, payload: .completed(text: "synthetic")))
        continuation.finish()
        return ProviderExecution(events: stream) { Task { await signal.mark() } }
    }
}

@MainActor
final class CodexExecutionHostTests: XCTestCase {
    struct Fixture {
        let root: URL
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID())
        let environment = EnvironmentID()
        let agent = AgentID()
        var locks: URL { root.appendingPathComponent("Locks") }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: locks, withIntermediateDirectories: false)
        }
        func remove() { try? FileManager.default.removeItem(at: root) }
        func resource() throws -> ExecutionResource { try GitRepositoryFiles(root: root).resource(in: scope) }
        func request(timeout: Int = 30) -> ExecutionRequest {
            ExecutionRequest(identity: ExecutionIdentity(scope: scope, runID: RunID(), agentID: agent, environmentID: environment),
                instructions: "Inspect synthetic files", task: "Report evidence", model: nil, timeout: .seconds(timeout), maximumActivities: 128)
        }
        func start(_ request: ExecutionRequest) throws -> CodexExecutionStart {
            try CodexExecutionStart(request: request, directory: root, executable: URL(fileURLWithPath: "/synthetic/codex"), resource: resource())
        }
    }
    private func call(_ session: CodexExecutionHostSession, _ operation: CodexExecutionHostRequest.Operation) async throws -> CodexExecutionHostReply {
        try await CodexExecutionHostWire.decode(CodexExecutionHostReply.self, from:
            session.perform(CodexExecutionHostWire.encode(CodexExecutionHostRequest(operation))))
    }
    func testPreparedTransportRoundTripAndSignedProviderAdapterPreserveIdentity() async throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = CoordinatorFakeProvider(resource: try f.resource(), mode: .success)
        let session = CodexExecutionHostSession(factory: { _ in fake }, lockDirectory: f.locks)
        let connection = LoopbackExecutionConnection(session)
        let provider = try CodexHostExecutionProvider(scope: f.scope, directory: f.root, executable: URL(fileURLWithPath: "/synthetic/codex"),
            connectionFactory: { connection })
        let request = f.request(), execution = try await provider.start(request)
        var events: [ExecutionProviderEvent] = []
        for try await event in execution.events { events.append(event) }
        XCTAssertEqual(events.map(\.sequence), [1,2,3,4,5])
        XCTAssertTrue(events.allSatisfy { $0.identity == request.identity })
        if case .completed = events.last?.payload {} else { XCTFail("Missing final event") }
        let requests = await fake.requests; XCTAssertEqual(requests.count, 1); XCTAssertEqual(requests.first?.task, request.task)
        await connection.close()
    }
    func testForeignResourceAndMalformedMessagesDoNotStartProvider() async throws {
        let f = try Fixture(); defer { f.remove() }
        let called = Mutex(0)
        let fake = CoordinatorFakeProvider(resource: try .directory(in: f.scope, device: 42, inode: 42), mode: .success)
        let session = CodexExecutionHostSession(factory: { _ in called.withLock { $0 += 1 }; return fake }, lockDirectory: f.locks)
        for data in [Data("not-json".utf8), Data(repeating: 0, count: CodexExecutionHostWire.maximumBytes + 1), Data("{\"schemaVersion\":99,\"operation\":{\"next\":{\"runID\":\"bad\",\"afterSequence\":0}}}".utf8)] {
            let reply = try await CodexExecutionHostWire.decode(CodexExecutionHostReply.self, from: session.perform(data))
            if case .failed = reply {} else { XCTFail("Malformed data accepted") }
        }
        XCTAssertEqual(called.withLock { $0 }, 0)
        let reply = try await call(session, .start(f.start(f.request())))
        if case .failed(.scopeMismatch) = reply {} else { XCTFail("Foreign physical root accepted") }
        let requests = await fake.requests; XCTAssertTrue(requests.isEmpty)
        await session.invalidate()
    }
    func testQuietDisconnectReleasesPendingReplyAndHelperProjectLease() async throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = CoordinatorFakeProvider(resource: try f.resource(), mode: .quiet)
        let session = CodexExecutionHostSession(factory: { _ in fake }, lockDirectory: f.locks)
        let request = f.request()
        _ = try await call(session, .start(f.start(request)))
        await fake.waitForStart()
        let first = try await call(session, .next(runID: request.identity.runID, afterSequence: 0))
        if case .event(let event) = first { XCTAssertEqual(event.sequence, 1) } else { XCTFail("Missing event") }
        let waiting = Task { try await self.call(session, .next(runID: request.identity.runID, afterSequence: 1)) }
        await session.invalidate()
        let ended = try await waiting.value
        if case .failed = ended {} else { XCTFail("Disconnected run continued") }
        XCTAssertEqual(fake.cancellations.withLock { $0 }, 1)
        let available = try RunCoordinatorLease(container: f.locks, scope: f.scope); try available.validate()
    }
    func testHelperExcludesConcurrentProjectAndRejectsCursorOrRunSubstitution() async throws {
        let f = try Fixture(); defer { f.remove() }
        let fake = CoordinatorFakeProvider(resource: try f.resource(), mode: .quiet)
        let first = CodexExecutionHostSession(factory: { _ in fake }, lockDirectory: f.locks)
        let second = CodexExecutionHostSession(factory: { _ in fake }, lockDirectory: f.locks)
        let request = f.request()
        _ = try await call(first, .start(f.start(request)))
        let blocked = try await call(second, .start(f.start(f.request())))
        if case .failed(.busy) = blocked {} else { XCTFail("Concurrent helper owner") }
        for operation: CodexExecutionHostRequest.Operation in [.next(runID: RunID(), afterSequence: 0),
            .next(runID: request.identity.runID, afterSequence: 2), .cancel(runID: RunID()), .start(try f.start(request))] {
            if case .failed = try await call(first, operation) {} else { XCTFail("Substituted or repeated operation") }
        }
        await first.invalidate(); await second.invalidate()
    }
    func testClientCancellationAndDeadlineCloseQuietTransport() async throws {
        for cancel in [true, false] {
            let f = try Fixture(); defer { f.remove() }
            let fake = CoordinatorFakeProvider(resource: try f.resource(), mode: .quiet)
            let session = CodexExecutionHostSession(factory: { _ in fake }, lockDirectory: f.locks)
            let connection = LoopbackExecutionConnection(session)
            let provider = try CodexHostExecutionProvider(scope: f.scope, directory: f.root, executable: URL(fileURLWithPath: "/synthetic/codex"),
                connectionFactory: { connection })
            let execution = try await provider.start(f.request(timeout: 1))
            let consumer = Task { for try await _ in execution.events {} }
            await fake.waitForStart()
            if cancel { execution.cancel() }
            do { try await consumer.value; XCTFail("Quiet transport completed") }
            catch { XCTAssertTrue(error is CancellationError || error as? ExecutionProviderError == .timedOut) }
            await connection.close()
            XCTAssertEqual(fake.cancellations.withLock { $0 }, 1)
        }
    }
    func testSlowConsumerOverflowFailsExplicitlyAndReleasesProvider() async throws {
        let f = try Fixture(); defer { f.remove() }
        let signal = HostCancellationSignal(), provider = BurstExecutionProvider(resource: try f.resource(), signal: signal)
        let session = CodexExecutionHostSession(factory: { _ in provider }, lockDirectory: f.locks)
        let request = f.request(); _ = try await call(session, .start(f.start(request)))
        await signal.wait()
        for cursor in 0..<64 {
            let reply = try await call(session, .next(runID: request.identity.runID, afterSequence: Int64(cursor)))
            if case .event(let event) = reply { XCTAssertEqual(event.sequence, Int64(cursor + 1)) }
            else { XCTFail("Lost queued observation") }
        }
        let terminal = try await call(session, .next(runID: request.identity.runID, afterSequence: 64))
        if case .failed(.consumerOverflow) = terminal {} else { XCTFail("Overflow was hidden") }
        await session.invalidate()
    }
    func testHelperDoesNotTreatLateErrorOrMissingCompletionAsSuccess() async throws {
        for mode: CoordinatorFakeProvider.Mode in [.lateError, .earlyEOF, .lateEvent] {
            let f = try Fixture(); defer { f.remove() }
            let fake = CoordinatorFakeProvider(resource: try f.resource(), mode: mode)
            let session = CodexExecutionHostSession(factory: { _ in fake }, lockDirectory: f.locks)
            let request = f.request(); _ = try await call(session, .start(f.start(request)))
            var cursor: Int64 = 0, failed = false
            while !failed {
                switch try await call(session, .next(runID: request.identity.runID, afterSequence: cursor)) {
                case .event(let event): cursor = event.sequence
                case .failed: failed = true
                default: XCTFail("Unverified stream succeeded"); failed = true
                }
            }
            await session.invalidate()
        }
    }
}
#endif
