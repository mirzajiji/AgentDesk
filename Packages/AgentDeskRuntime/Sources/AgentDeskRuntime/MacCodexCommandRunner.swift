#if os(macOS)
import Darwin
import Foundation

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

/// Argument-array spawning with a new process group. No shell parsing or inherited arbitrary environment.
/// Raw output exists only in bounded memory for the normalized diagnostics parser.
enum MacCommandCapture {
    static func run(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                    timeout: Duration, maximumBytes: Int) async throws -> CLICommandOutput {
        try Task.checkCancellation()
        guard timeout > .zero, timeout <= .seconds(300), (1...1_048_576).contains(maximumBytes),
              arguments.count <= 128, arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 65_536 }),
              environment.count <= 64, environment.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 100 && $0.value.utf8.count <= 65_536 && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }) else {
            throw CodexDiagnosticIssue.commandFailed
        }
        let child = try spawn(executable: executable, arguments: arguments, directory: directory, environment: environment)
        var reaped = false
        defer {
            // Also terminate descendants that outlive the command while retaining its pipes.
            kill(-child.pid, SIGKILL)
            if !reaped {
                var status: Int32 = 0
                while waitpid(child.pid, &status, 0) == -1 && errno == EINTR {}
            }
            close(child.output); close(child.error)
        }
        let clock = ContinuousClock(), deadline = clock.now + timeout
        var stdout = Data(), stderr = Data(), stdoutEOF = false, stderrEOF = false
        var exitStatus: Int32 = 0
        var exitedAt: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw CodexDiagnosticIssue.timedOut }
            try drain(child.output, into: &stdout, eof: &stdoutEOF, maximum: maximumBytes - stderr.count)
            try drain(child.error, into: &stderr, eof: &stderrEOF, maximum: maximumBytes - stdout.count)
            if !reaped {
                let status = waitpid(child.pid, &exitStatus, WNOHANG)
                if status == child.pid { reaped = true; exitedAt = clock.now }
                else if status == -1 && errno != EINTR { throw CodexDiagnosticIssue.commandFailed }
            }
            if reaped && stdoutEOF && stderrEOF { break }
            if let exitedAt, clock.now - exitedAt >= .milliseconds(100) { kill(-child.pid, SIGKILL) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let signal = exitStatus & 0x7f
        let code = signal == 0 ? (exitStatus >> 8) & 0xff : 128 + signal
        return CLICommandOutput(status: code, stdout: stdout, stderr: stderr)
    }

    private static func drain(_ descriptor: Int32, into data: inout Data, eof: inout Bool, maximum: Int) throws {
        guard !eof else { return }
        var buffer = [UInt8](repeating: 0, count: 8_192)
        for _ in 0..<16 {
            let count = read(descriptor, &buffer, buffer.count)
            if count == 0 { eof = true; return }
            if count < 0 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return }
                if errno == EINTR { continue }
                throw CodexDiagnosticIssue.commandFailed
            }
            guard count <= maximum - data.count else { throw CodexDiagnosticIssue.outputLimit }
            data.append(contentsOf: buffer.prefix(count))
        }
    }

    private struct Child { let pid: pid_t; let output: Int32; let error: Int32 }

    private static func spawn(executable: URL, arguments: [String], directory: URL,
                              environment: [String: String]) throws -> Child {
        var output: [Int32] = [-1, -1], error: [Int32] = [-1, -1]
        guard pipe(&output) == 0 else { throw CodexDiagnosticIssue.commandFailed }
        guard pipe(&error) == 0 else { close(output[0]); close(output[1]); throw CodexDiagnosticIssue.commandFailed }
        var success = false
        defer {
            close(output[1]); close(error[1])
            if !success { close(output[0]); close(error[0]) }
        }
        var actions: posix_spawn_file_actions_t?, attributes: posix_spawnattr_t?
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw CodexDiagnosticIssue.commandFailed }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attributes) == 0 else { throw CodexDiagnosticIssue.commandFailed }
        defer { posix_spawnattr_destroy(&attributes) }
        func check(_ code: Int32) throws { guard code == 0 else { throw CodexDiagnosticIssue.commandFailed } }
        try check(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK)))
        try check(posix_spawnattr_setpgroup(&attributes, 0))
        var defaults = sigset_t(), mask = sigset_t()
        sigfillset(&defaults); sigdelset(&defaults, SIGKILL); sigdelset(&defaults, SIGSTOP); sigemptyset(&mask)
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults))
        try check(posix_spawnattr_setsigmask(&attributes, &mask))
        try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try check(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, error[1], STDERR_FILENO))
        for descriptor in output + error where descriptor > STDERR_FILENO {
            try check(posix_spawn_file_actions_addclose(&actions, descriptor))
        }
        if #available(macOS 26, *) {
            try check(posix_spawn_file_actions_addchdir(&actions, directory.path))
        } else {
            try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path))
        }
        try check(fcntl(output[0], F_SETFL, O_NONBLOCK) == -1 ? errno : 0)
        try check(fcntl(error[0], F_SETFL, O_NONBLOCK) == -1 ? errno : 0)
        let strings = [executable.path] + arguments
        var argv = strings.map { strdup($0) } + [nil]
        var envp = environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else {
            throw CodexDiagnosticIssue.commandFailed
        }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp)
        guard result == 0 else {
            throw result == EACCES || result == EPERM ? CodexDiagnosticIssue.permissionDenied : CodexDiagnosticIssue.commandFailed
        }
        success = true
        return Child(pid: pid, output: output[0], error: error[0])
    }
}
#endif
