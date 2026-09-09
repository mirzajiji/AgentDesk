#if os(macOS)
import Foundation

/// Injectable subprocess boundary; production always delegates to the bounded native transport.
protocol CodexProcessExecuting: Sendable {
    func run(executable: URL, arguments: [String], directory: URL, environment: [String: String],
             input: MacProcessInputPipe, timeout: Duration, maximumBytes: Int,
             output: @Sendable (MacProcessChunk) throws -> Void) async throws -> MacProcessExit
}
struct MacCodexProcess: CodexProcessExecuting {
    func run(executable: URL, arguments: [String], directory: URL, environment: [String: String],
             input: MacProcessInputPipe, timeout: Duration, maximumBytes: Int,
             output: @Sendable (MacProcessChunk) throws -> Void) async throws -> MacProcessExit {
        try await MacProcessRunner.run(executable: executable, arguments: arguments, directory: directory,
            environment: environment, interactiveInput: input, timeout: timeout, maximumBytes: maximumBytes, output: output)
    }
}
#endif
