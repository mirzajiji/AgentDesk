import Foundation

public enum CodexAuthentication: String, Codable, Sendable, Equatable {
    case unknown, signedOut, chatGPT, unsupportedMethod
}

public enum CodexDiagnosticIssue: String, Codable, Error, Sendable, Equatable {
    case notInstalled, invalidExecutable, incompatibleCLI, permissionDenied, timedOut, outputLimit, commandFailed, busy
}

public struct CodexCapabilities: Codable, Sendable, Equatable {
    public let login: Bool
    public let logout: Bool
    public let loginStatus: Bool
    public let jsonExecution: Bool
    public let stdinPrompt: Bool
    public let ephemeralExecution: Bool
    public let ignoreUserConfig: Bool
}

public struct CodexInstallation: Codable, Sendable, Equatable {
    public let executable: URL
    public let version: String
    public let capabilities: CodexCapabilities
}

/// Only normalized public CLI facts. No raw diagnostics, account tokens, or inferred subscription data.
public struct CodexDiagnosticSnapshot: Codable, Sendable, Equatable {
    public let installation: CodexInstallation?
    public let authentication: CodexAuthentication
    public let issue: CodexDiagnosticIssue?
    public init(installation: CodexInstallation?, authentication: CodexAuthentication, issue: CodexDiagnosticIssue?) {
        self.installation = installation; self.authentication = authentication; self.issue = issue
    }
}

public protocol CodexDiagnosing: Sendable {
    func inspect(executable: URL?) async throws -> CodexDiagnosticSnapshot
    func login(using installation: CodexInstallation) async throws -> CodexDiagnosticSnapshot
    func logout(using installation: CodexInstallation) async throws -> CodexDiagnosticSnapshot
}

enum CodexControlCommand: Sendable {
    case version, help, loginHelp, execHelp, status, login, logout
    var arguments: [String] {
        switch self {
        case .version: ["--version"]
        case .help: ["--help"]
        case .loginHelp: ["login", "--help"]
        case .execHelp: ["exec", "--help"]
        case .status: ["login", "status"]
        case .login: ["login"]
        case .logout: ["logout"]
        }
    }
    var timeout: Duration { self == .login ? .seconds(180) : .seconds(10) }
}

struct CLICommandOutput: Sendable {
    let status: Int32
    let stdout: Data
    let stderr: Data
    var text: String { String(decoding: stdout, as: UTF8.self) + "\n" + String(decoding: stderr, as: UTF8.self) }
}

protocol CodexCommandRunning: Sendable {
    func run(executable: URL, command: CodexControlCommand) async throws -> CLICommandOutput
}

enum CodexOutputParser {
    static func version(_ result: CLICommandOutput) throws -> String {
        let text = result.stdout.isEmpty ? String(decoding: result.stderr, as: UTF8.self) : String(decoding: result.stdout, as: UTF8.self)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard result.status == 0, value.utf8.count <= 100,
              value.range(of: #"^codex-cli [0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?$"#, options: .regularExpression) != nil else {
            throw CodexDiagnosticIssue.incompatibleCLI
        }
        return String(value.dropFirst("codex-cli ".count))
    }

    static func capabilities(help: CLICommandOutput, login: CLICommandOutput, exec: CLICommandOutput) throws -> CodexCapabilities {
        guard help.status == 0, help.text.contains("Usage: codex"), login.status == 0, exec.status == 0 else {
            throw CodexDiagnosticIssue.incompatibleCLI
        }
        func command(_ name: String, in text: String) -> Bool {
            text.split(separator: "\n").contains { $0.split(whereSeparator: \.isWhitespace).first == Substring(name) }
        }
        func flag(_ name: String) -> Bool {
            exec.text.split(whereSeparator: \.isWhitespace).contains(Substring(name))
        }
        return CodexCapabilities(login: command("login", in: help.text), logout: command("logout", in: help.text),
            loginStatus: command("status", in: login.text), jsonExecution: flag("--json"),
            stdinPrompt: exec.text.contains("read from stdin"), ephemeralExecution: flag("--ephemeral"), ignoreUserConfig: flag("--ignore-user-config"))
    }

    static func authentication(_ result: CLICommandOutput) -> (CodexAuthentication, CodexDiagnosticIssue?) {
        let lines = result.text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if result.status == 0, lines.contains("Logged in using ChatGPT") { return (.chatGPT, nil) }
        if result.status == 1, lines.contains("Not logged in") { return (.signedOut, nil) }
        if result.status == 0, lines.contains(where: { $0.hasPrefix("Logged in using an API key") || $0.hasPrefix("Logged in using API key") }) {
            return (.unsupportedMethod, nil)
        }
        return (.unknown, .commandFailed)
    }
}
