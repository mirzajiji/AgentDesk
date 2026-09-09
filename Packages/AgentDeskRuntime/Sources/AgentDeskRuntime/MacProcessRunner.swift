#if os(macOS)
import Darwin
import Foundation

struct MacProcessChunk: Sendable {
    enum Channel: Sendable { case stdout, stderr }
    let channel: Channel
    let bytes: Data
}

struct MacProcessExit: Sendable, Equatable {
    let code: Int32?
    let signal: Int32?
    var status: Int32 { code ?? (128 + (signal ?? 0)) }
}

/// Internal transport, not an authorization boundary or a remote command API.
/// The synchronous sink must return promptly; throwing (including on queue overflow) terminates the group.
/// Raw bytes stay untrusted. Callers must frame, validate and redact before persistence or display.
enum MacProcessRunner {
    static func run(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                    input: Data? = nil, interactiveInput: MacProcessInputPipe? = nil, timeout: Duration, maximumBytes: Int,
                    output: @Sendable (MacProcessChunk) throws -> Void) async throws -> MacProcessExit {
        try Task.checkCancellation()
        let local: (URL) -> Bool = { $0.isFileURL && $0.path.hasPrefix("/") && !$0.path.utf8.contains(0) && ($0.host == nil || $0.host == "localhost") }
        guard !(input != nil && interactiveInput != nil), local(executable), local(directory), timeout > .zero, timeout <= .seconds(3_600),
              (1...16_777_216).contains(maximumBytes), (input?.count ?? 0) <= 1_048_576,
              arguments.count <= 128, arguments.allSatisfy({ !$0.utf8.contains(0) && $0.utf8.count <= 65_536 }),
              arguments.reduce(0, { $0 + $1.utf8.count }) <= 131_072,
              environment.count <= 64,
              environment.allSatisfy({ !$0.key.isEmpty && $0.key.utf8.count <= 100 && $0.value.utf8.count <= 65_536 && !$0.key.contains("=") && !$0.key.utf8.contains(0) && !$0.value.utf8.contains(0) }),
              environment.reduce(0, { $0 + $1.key.utf8.count + $1.value.utf8.count }) <= 131_072 else {
            throw CodexDiagnosticIssue.commandFailed
        }
        let source: MacProcessInputPipe?
        if let input {
            let pipe = MacProcessInputPipe(); try pipe.write(input); pipe.close(); source = pipe
        } else { source = interactiveInput }
        defer { source?.cancel() }
        let child = try spawn(executable: executable, arguments: arguments, directory: directory,
                              environment: environment, hasInput: source != nil)
        var reaped = false, inputFD = child.input
        defer {
            kill(-child.pid, SIGKILL)
            if !reaped {
                var status: Int32 = 0
                while waitpid(child.pid, &status, 0) == -1 && errno == EINTR {}
            }
            if inputFD >= 0 { close(inputFD) }
            close(child.output); close(child.error)
        }
        let clock = ContinuousClock(), deadline = clock.now + timeout
        var pendingInput: Data?
        var total = 0, inputOffset = 0, stdoutEOF = false, stderrEOF = false, exitStatus: Int32 = 0
        var exitedAt: ContinuousClock.Instant?
        while true {
            try Task.checkCancellation()
            guard clock.now < deadline else { throw CodexDiagnosticIssue.timedOut }
            try drain(child.output, channel: .stdout, eof: &stdoutEOF, total: &total, maximum: maximumBytes, output: output)
            try drain(child.error, channel: .stderr, eof: &stderrEOF, total: &total, maximum: maximumBytes, output: output)
            if inputFD >= 0, let source {
                if reaped { close(inputFD); inputFD = -1 }
                else {
                    if pendingInput == nil {
                        switch source.read() {
                        case .bytes(let bytes): pendingInput = bytes; inputOffset = 0
                        case .waiting: break
                        case .end: close(inputFD); inputFD = -1
                        }
                    }
                    if inputFD >= 0, let bytes = pendingInput {
                        if try feed(bytes, offset: &inputOffset, descriptor: inputFD, earlyCloseIsError: interactiveInput != nil) {
                            pendingInput = nil
                        }
                    }
                }
            }
            if !reaped {
                let status = waitpid(child.pid, &exitStatus, WNOHANG)
                if status == child.pid { reaped = true; exitedAt = clock.now }
                else if status == -1 && errno != EINTR { throw CodexDiagnosticIssue.commandFailed }
            }
            if reaped && stdoutEOF && stderrEOF {
                try Task.checkCancellation()
                let signal = exitStatus & 0x7f
                return MacProcessExit(code: signal == 0 ? (exitStatus >> 8) & 0xff : nil, signal: signal == 0 ? nil : signal)
            }
            if let exitedAt, clock.now - exitedAt >= .milliseconds(100) { kill(-child.pid, SIGKILL) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func feed(_ input: Data, offset: inout Int, descriptor: Int32, earlyCloseIsError: Bool) throws -> Bool {
        for _ in 0..<16 {
            if offset == input.count { return true }
            let count = input.withUnsafeBytes { bytes in
                write(descriptor, bytes.baseAddress!.advanced(by: offset), min(8_192, bytes.count - offset))
            }
            if count > 0 { offset += count; continue }
            if count == -1 {
                if errno == EAGAIN || errno == EWOULDBLOCK { return false }
                if errno == EINTR { continue }
                // The child can choose to stop reading. F_SETNOSIGPIPE prevents killing the host.
                if errno == EPIPE {
                    if earlyCloseIsError { throw CodexDiagnosticIssue.commandFailed }
                    offset = input.count; return true
                }
            }
            throw CodexDiagnosticIssue.commandFailed
        }
        return offset == input.count
    }

    private static func drain(_ descriptor: Int32, channel: MacProcessChunk.Channel, eof: inout Bool,
                              total: inout Int, maximum: Int, output: (MacProcessChunk) throws -> Void) throws {
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
            guard count <= maximum - total else { throw CodexDiagnosticIssue.outputLimit }
            total += count
            try output(MacProcessChunk(channel: channel, bytes: Data(buffer.prefix(count))))
        }
    }

    private struct Child { let pid: pid_t; let input: Int32; let output: Int32; let error: Int32 }

    private static func pipeDescriptors() throws -> [Int32] {
        var descriptors: [Int32] = [-1, -1]
        guard pipe(&descriptors) == 0 else { throw CodexDiagnosticIssue.commandFailed }
        var success = false
        defer { if !success { descriptors.forEach { close($0) } } }
        for index in descriptors.indices {
            // Keep endpoints above stdin/stdout/stderr even if the embedding host closed a standard FD.
            let original = descriptors[index]
            let duplicated = fcntl(original, F_DUPFD_CLOEXEC, 3)
            guard duplicated >= 0 else { throw CodexDiagnosticIssue.commandFailed }
            descriptors[index] = duplicated; close(original)
        }
        success = true; return descriptors
    }

    private static func spawn(executable: URL, arguments: [String], directory: URL,
                              environment: [String: String], hasInput: Bool) throws -> Child {
        let output = try pipeDescriptors()
        var error: [Int32] = [], input: [Int32] = []
        var success = false
        defer {
            if success {
                close(output[1]); close(error[1]); if hasInput { close(input[0]) }
            } else { (output + error + input).forEach { close($0) } }
        }
        error = try pipeDescriptors()
        if hasInput { input = try pipeDescriptors() }
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
        try check(posix_spawnattr_setsigdefault(&attributes, &defaults)); try check(posix_spawnattr_setsigmask(&attributes, &mask))
        if hasInput {
            try check(posix_spawn_file_actions_adddup2(&actions, input[0], STDIN_FILENO))
            try check(fcntl(input[1], F_SETFL, O_NONBLOCK) == -1 ? errno : 0)
            try check(fcntl(input[1], F_SETNOSIGPIPE, 1) == -1 ? errno : 0)
        } else { try check(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)) }
        try check(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO))
        try check(posix_spawn_file_actions_adddup2(&actions, error[1], STDERR_FILENO))
        for descriptor in output + error + input { try check(posix_spawn_file_actions_addclose(&actions, descriptor)) }
        if #available(macOS 26, *) { try check(posix_spawn_file_actions_addchdir(&actions, directory.path)) }
        else { try check(posix_spawn_file_actions_addchdir_np(&actions, directory.path)) }
        try check(fcntl(output[0], F_SETFL, O_NONBLOCK) == -1 ? errno : 0)
        try check(fcntl(error[0], F_SETFL, O_NONBLOCK) == -1 ? errno : 0)
        var argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        var envp = environment.sorted(by: { $0.key < $1.key }).map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.dropLast().allSatisfy({ $0 != nil }), envp.dropLast().allSatisfy({ $0 != nil }) else { throw CodexDiagnosticIssue.commandFailed }
        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable.path, &actions, &attributes, &argv, &envp)
        guard result == 0 else { throw result == EACCES || result == EPERM ? CodexDiagnosticIssue.permissionDenied : CodexDiagnosticIssue.commandFailed }
        success = true
        return Child(pid: pid, input: hasInput ? input[1] : -1, output: output[0], error: error[0])
    }
}
#endif
