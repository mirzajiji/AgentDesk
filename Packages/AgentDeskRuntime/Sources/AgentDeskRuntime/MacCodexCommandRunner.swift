#if os(macOS)
import Darwin
import Foundation
import Synchronization

struct MacCodexCommandRunner: CodexCommandRunning {
    func run(executable: URL, command: CodexControlCommand) async throws -> CLICommandOutput {
        let location = try CodexExecutableLocator.validate(executable)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDesk-Codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let allowed = Set(["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "LANG", "LC_ALL", "CODEX_HOME"])
        var environment = ProcessInfo.processInfo.environment.filter { allowed.contains($0.key) }
        environment["NO_COLOR"] = "1"
        return try await MacCommandCapture.run(executable: location, arguments: command.arguments, directory: directory,
            environment: environment, timeout: command.timeout, maximumBytes: 65_536)
    }
}

/// Diagnostics collect streamed bytes within their tighter output and duration limits.
enum MacCommandCapture {
    static func run(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                    timeout: Duration, maximumBytes: Int) async throws -> CLICommandOutput {
        guard timeout <= .seconds(300), maximumBytes <= 1_048_576 else { throw CodexDiagnosticIssue.commandFailed }
        let output = Mutex((stdout: Data(), stderr: Data()))
        let exit = try await MacProcessRunner.run(executable: executable, arguments: arguments, directory: directory,
            environment: environment, timeout: timeout, maximumBytes: maximumBytes) { chunk in
            output.withLock { captured in
                switch chunk.channel {
                case .stdout: captured.stdout.append(chunk.bytes)
                case .stderr: captured.stderr.append(chunk.bytes)
                }
            }
        }
        return output.withLock { CLICommandOutput(status: exit.status, stdout: $0.stdout, stderr: $0.stderr) }
    }
}
#endif
