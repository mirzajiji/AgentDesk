#if os(macOS)
import Foundation
import Synchronization

/// Bounded stdin mailbox for request/response CLI protocols. Closing drains accepted bytes then sends EOF.
final class MacProcessInputPipe: Sendable {
    enum Read: Sendable { case bytes(Data), waiting, end }
    private struct State {
        var chunks: [Data] = []
        var queuedBytes = 0
        var acceptedBytes = 0
        var closed = false
        var aborted = false
    }
    private let state = Mutex(State())

    func write(_ bytes: Data) throws {
        try state.withLock {
            guard !$0.closed, !$0.aborted else { throw CodexDiagnosticIssue.commandFailed }
            guard (bytes.isEmpty || $0.chunks.count < 128), bytes.count <= 1_048_576 - $0.queuedBytes,
                  bytes.count <= 16_777_216 - $0.acceptedBytes else { throw CodexDiagnosticIssue.outputLimit }
            if !bytes.isEmpty { $0.chunks.append(bytes) }
            $0.queuedBytes += bytes.count; $0.acceptedBytes += bytes.count
        }
    }
    func close() { state.withLock { $0.closed = true } }
    func cancel() {
        state.withLock { $0.aborted = true; $0.closed = true; $0.chunks.removeAll(); $0.queuedBytes = 0 }
    }
    func read() -> Read {
        state.withLock {
            guard !$0.aborted else { return .end }
            if !$0.chunks.isEmpty {
                let next = $0.chunks.removeFirst(); $0.queuedBytes -= next.count
                return .bytes(next)
            }
            return $0.closed ? .end : .waiting
        }
    }
}
#endif
