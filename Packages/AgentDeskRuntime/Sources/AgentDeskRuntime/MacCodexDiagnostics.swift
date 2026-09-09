#if os(macOS)
import Foundation

/// Local Mac provider configuration, not a workspace tool or remote command endpoint.
public actor MacCodexDiagnostics: CodexDiagnosing {
    private let runner: any CodexCommandRunning
    private let locate: @Sendable (URL?) throws -> URL
    private var inFlight = false

    public init() {
        runner = MacCodexCommandRunner()
        locate = CodexExecutableLocator.locate
    }

    init(runner: any CodexCommandRunning, locate: @escaping @Sendable (URL?) throws -> URL) {
        self.runner = runner; self.locate = locate
    }

    public func inspect(executable: URL? = nil) async throws -> CodexDiagnosticSnapshot {
        try begin(); defer { inFlight = false }
        return try await inspectUnlocked(executable)
    }

    public func login(using installation: CodexInstallation) async throws -> CodexDiagnosticSnapshot {
        try await changeAuthentication(installation, command: .login)
    }

    public func logout(using installation: CodexInstallation) async throws -> CodexDiagnosticSnapshot {
        try await changeAuthentication(installation, command: .logout)
    }

    private func changeAuthentication(_ installation: CodexInstallation, command: CodexControlCommand) async throws -> CodexDiagnosticSnapshot {
        try begin(); defer { inFlight = false }
        // Re-probe the selected executable; stale Settings state cannot authorize an unsupported command.
        let current = try await inspectUnlocked(installation.executable)
        guard let verified = current.installation, verified.executable == installation.executable,
              command == .login ? verified.capabilities.login : verified.capabilities.logout else {
            throw current.issue ?? CodexDiagnosticIssue.incompatibleCLI
        }
        let result = try await runner.run(executable: verified.executable, command: command)
        guard result.status == 0 else { throw CodexDiagnosticIssue.commandFailed }
        return try await inspectUnlocked(verified.executable)
    }

    private func inspectUnlocked(_ requested: URL?) async throws -> CodexDiagnosticSnapshot {
        var installation: CodexInstallation?
        do {
            let executable = try locate(requested)
            let version = try CodexOutputParser.version(await runner.run(executable: executable, command: .version))
            let help = try await runner.run(executable: executable, command: .help)
            let login = try await runner.run(executable: executable, command: .loginHelp)
            let exec = try await runner.run(executable: executable, command: .execHelp)
            let capabilities = try CodexOutputParser.capabilities(help: help, login: login, exec: exec)
            installation = CodexInstallation(executable: executable, version: version, capabilities: capabilities)
            guard capabilities.loginStatus else { throw CodexDiagnosticIssue.incompatibleCLI }
            let result = try await runner.run(executable: executable, command: .status)
            let (authentication, issue) = CodexOutputParser.authentication(result)
            return CodexDiagnosticSnapshot(installation: installation, authentication: authentication, issue: issue)
        } catch is CancellationError { throw CancellationError() }
        catch { return CodexDiagnosticSnapshot(installation: installation, authentication: .unknown, issue: error as? CodexDiagnosticIssue ?? .commandFailed) }
    }

    private func begin() throws {
        try Task.checkCancellation()
        guard !inFlight else { throw CodexDiagnosticIssue.busy }
        inFlight = true
    }
}

enum CodexExecutableLocator {
    static func locate(_ requested: URL?) throws -> URL {
        if let requested { return try validate(requested) }
        let candidates = ["/opt/homebrew/bin/codex", "/usr/local/bin/codex",
                          "/Applications/ChatGPT.app/Contents/Resources/codex", "/Applications/Codex.app/Contents/Resources/codex"]
        for candidate in candidates {
            if let executable = try? validate(URL(fileURLWithPath: candidate)) { return executable }
        }
        throw CodexDiagnosticIssue.notInstalled
    }

    static func validate(_ location: URL) throws -> URL {
        guard location.isFileURL, location.path.hasPrefix("/"), location.host == nil || location.host == "localhost",
              !location.path.utf8.contains(0) else { throw CodexDiagnosticIssue.invalidExecutable }
        let resolved = location.resolvingSymlinksInPath().standardizedFileURL
        guard let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey]), values.isRegularFile == true else {
            throw CodexDiagnosticIssue.invalidExecutable
        }
        guard FileManager.default.isExecutableFile(atPath: resolved.path) else { throw CodexDiagnosticIssue.permissionDenied }
        return resolved
    }
}
#endif
