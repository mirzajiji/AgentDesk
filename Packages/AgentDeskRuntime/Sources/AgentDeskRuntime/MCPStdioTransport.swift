#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import Foundation
import Synchronization

enum MCPProcessError: Error, Equatable, Sendable {
    case closed, invalidFrame, receiveOverflow, processFailed, timedOut
}

/// Internal byte transport for an already authorized local launch. It does not grant tool authority.
/// A session must negotiate protocol/version and validate scoped configuration before dispatch.
actor MCPStdioTransport {
    nonisolated let scope: ProjectScope
    nonisolated let connectionID: UUID
    nonisolated let messages: AsyncThrowingStream<MCPMessage, any Error>
    private let input: MacProcessInputPipe
    private let process: Task<Void, Never>
    private var closed = false

    init(scope: ProjectScope, connectionID: UUID, executable: URL, arguments: [String], directory: URL,
         environment: [String: String] = [:], timeout: Duration = .seconds(3600)) throws {
        self.scope = scope; self.connectionID = connectionID
        let input = MacProcessInputPipe(); self.input = input
        let pair = AsyncThrowingStream<MCPMessage, any Error>.makeStream(bufferingPolicy: .bufferingOldest(128))
        messages = pair.stream
        let decoder = Mutex(try MCPLineDecoder())
        let running = Task {
            do {
                let exit = try await MacProcessRunner.run(executable: executable, arguments: arguments, directory: directory,
                    environment: environment, interactiveInput: input, timeout: timeout, maximumBytes: 16_777_216) { chunk in
                    guard case .stdout = chunk.channel else { return }
                    let frames = try decoder.withLock { try $0.append(chunk.bytes) }
                    for frame in frames {
                        switch pair.continuation.yield(frame) {
                        case .enqueued: break
                        case .dropped: throw MCPProcessError.receiveOverflow
                        case .terminated: throw CancellationError()
                        @unknown default: throw MCPProcessError.receiveOverflow
                        }
                    }
                }
                try decoder.withLock { try $0.finish() }
                guard exit.status == 0 else { throw MCPProcessError.processFailed }
                pair.continuation.finish()
            } catch is CancellationError { pair.continuation.finish(throwing: CancellationError()) }
            catch CodexDiagnosticIssue.timedOut { pair.continuation.finish(throwing: MCPProcessError.timedOut) }
            catch let error as MCPWireError { pair.continuation.finish(throwing: error) }
            catch let error as MCPProcessError { pair.continuation.finish(throwing: error) }
            catch { pair.continuation.finish(throwing: MCPProcessError.processFailed) }
            input.cancel()
        }
        process = running
        pair.continuation.onTermination = { _ in input.cancel(); running.cancel() }
    }
    deinit { input.cancel(); process.cancel() }
    func waitForExit() async { await process.value }
    func send(_ message: MCPMessage) throws {
        try Task.checkCancellation()
        guard !closed else { throw MCPProcessError.closed }
        guard !message.bytes.contains(10), !message.bytes.contains(13) else { throw MCPProcessError.invalidFrame }
        try input.write(message.bytes + Data([10]))
    }
    /// Graceful EOF; the configured process lifetime remains the maximum wait.
    func finishInput() { closed = true; input.close() }
    /// Cancels, kills/reaps the process group and closes pipes before returning.
    func close() async { closed = true; input.cancel(); process.cancel(); await process.value }
}
#endif
