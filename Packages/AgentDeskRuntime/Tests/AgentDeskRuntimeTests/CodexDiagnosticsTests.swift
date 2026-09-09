import Foundation
import XCTest
@testable import AgentDeskRuntime

final class CodexDiagnosticsTests: XCTestCase {
    static func output(_ text: String, status: Int32 = 0, stderr: Bool = false) -> CLICommandOutput {
        CLICommandOutput(status: status, stdout: stderr ? Data() : Data(text.utf8), stderr: stderr ? Data(text.utf8) : Data())
    }

    func testVersionIsStrictAndDoesNotSurfaceArbitraryDiagnosticOutput() throws {
        XCTAssertEqual(try CodexOutputParser.version(Self.output("codex-cli 0.153.4\n")), "0.153.4")
        XCTAssertEqual(try CodexOutputParser.version(Self.output("codex-cli 1.0.0-beta.2", stderr: true)), "1.0.0-beta.2")
        for value in ["not-codex 1.0.0", "codex-cli unknown", "codex-cli 1.0.0\nprivate diagnostic", "codex-cli 1.0.0 secret"] {
            XCTAssertThrowsError(try CodexOutputParser.version(Self.output(value)))
        }
        XCTAssertThrowsError(try CodexOutputParser.version(Self.output("codex-cli 1.0.0", status: 1)))
    }

    func testAuthenticationRequiresMatchingPublicOutputAndExitStatus() {
        XCTAssertEqual(CodexOutputParser.authentication(Self.output("Logged in using ChatGPT", stderr: true)).0, .chatGPT)
        XCTAssertEqual(CodexOutputParser.authentication(Self.output("Not logged in", status: 1)).0, .signedOut)
        XCTAssertEqual(CodexOutputParser.authentication(Self.output("Logged in using an API key - synthetic-redacted")).0, .unsupportedMethod)
        for result in [Self.output("Logged in using ChatGPT", status: 1), Self.output("Not logged in"), Self.output("unknown"), Self.output("Error reading credentials", status: 1)] {
            let (authentication, issue) = CodexOutputParser.authentication(result)
            XCTAssertEqual(authentication, .unknown); XCTAssertEqual(issue, .commandFailed)
        }
    }

    func testCapabilitiesFollowInstalledHelpAndDoNotInventOptionalFlags() throws {
        let caps = try CodexOutputParser.capabilities(help: Self.output("Usage: codex [OPTIONS]\n  login Manage login\n  logout Remove credentials"),
            login: Self.output("Commands:\n status Show status"), exec: Self.output("--json\n--ephemeral\n--ignore-user-config\nInstructions are read from stdin"))
        XCTAssertTrue(caps.login && caps.logout && caps.loginStatus && caps.jsonExecution && caps.stdinPrompt && caps.ephemeralExecution && caps.ignoreUserConfig)
        let old = try CodexOutputParser.capabilities(help: Self.output("Usage: codex [OPTIONS]"), login: Self.output("Usage: codex login"), exec: Self.output("--json-extra"))
        XCTAssertFalse(old.login || old.logout || old.loginStatus || old.jsonExecution || old.stdinPrompt || old.ephemeralExecution || old.ignoreUserConfig)
        XCTAssertThrowsError(try CodexOutputParser.capabilities(help: Self.output("another tool"), login: Self.output(""), exec: Self.output("")))
    }

    func testCommandsUseOnlySupportedArgumentArraysWithoutCredentialInput() {
        XCTAssertEqual(CodexControlCommand.status.arguments, ["login", "status"])
        XCTAssertEqual(CodexControlCommand.login.arguments, ["login"])
        XCTAssertEqual(CodexControlCommand.logout.arguments, ["logout"])
        XCTAssertEqual(CodexControlCommand.login.timeout, .seconds(180))
        XCTAssertEqual(CodexControlCommand.status.timeout, .seconds(10))
    }
}

#if os(macOS)
@MainActor
final class MacCodexDiagnosticsTests: XCTestCase {
    private actor FakeRunner: CodexCommandRunning {
        var calls: [[String]] = []
        var signedIn = true
        let failure: CodexDiagnosticIssue?
        let delay: Duration
        init(failure: CodexDiagnosticIssue? = nil, delay: Duration = .zero) { self.failure = failure; self.delay = delay }
        func run(executable: URL, command: CodexControlCommand) async throws -> CLICommandOutput {
            try Task.checkCancellation()
            calls.append(command.arguments)
            if let failure { throw failure }
            if command == .version && delay > .zero { try await Task.sleep(for: delay) }
            switch command {
            case .version: return CodexDiagnosticsTests.output("codex-cli 0.153.4")
            case .help: return CodexDiagnosticsTests.output("Usage: codex [OPTIONS]\n login Manage login\n logout Remove credentials")
            case .loginHelp: return CodexDiagnosticsTests.output("Commands:\n status Show status")
            case .execHelp: return CodexDiagnosticsTests.output("--json\n--ephemeral\n--ignore-user-config\nInstructions are read from stdin")
            case .status: return CodexDiagnosticsTests.output(signedIn ? "Logged in using ChatGPT" : "Not logged in", status: signedIn ? 0 : 1)
            case .login: signedIn = true; return CodexDiagnosticsTests.output("success")
            case .logout: signedIn = false; return CodexDiagnosticsTests.output("success")
            }
        }
    }
    private let executable = URL(fileURLWithPath: "/synthetic/codex")

    func testInspectAndAuthenticationActionsProbeCapabilitiesAndRefreshFacts() async throws {
        let runner = FakeRunner(), path = executable
        let service = MacCodexDiagnostics(runner: runner, locate: { _ in path })
        let initial = try await service.inspect()
        XCTAssertEqual(initial.authentication, .chatGPT); XCTAssertNil(initial.issue)
        let installation = try XCTUnwrap(initial.installation)
        let loggedOut = try await service.logout(using: installation)
        XCTAssertEqual(loggedOut.authentication, .signedOut)
        let loggedIn = try await service.login(using: installation)
        XCTAssertEqual(loggedIn.authentication, .chatGPT)
        let calls = await runner.calls
        XCTAssertEqual(calls.filter { $0 == ["logout"] }.count, 1)
        XCTAssertEqual(calls.filter { $0 == ["login"] }.count, 1)
        XCTAssertEqual(calls.filter { $0 == ["--version"] }.count, 5)
    }

    func testMissingAndPermissionFailureStayDistinctAndDoNotExposeRawOutput() async throws {
        let runner = FakeRunner()
        let missing = MacCodexDiagnostics(runner: runner, locate: { _ in throw CodexDiagnosticIssue.notInstalled })
        let absent = try await missing.inspect()
        XCTAssertEqual(absent.issue, .notInstalled); XCTAssertNil(absent.installation)
        let calls = await runner.calls; XCTAssertTrue(calls.isEmpty)
        let path = executable
        let denied = MacCodexDiagnostics(runner: FakeRunner(failure: .permissionDenied), locate: { _ in path })
        let failure = try await denied.inspect()
        XCTAssertEqual(failure.issue, .permissionDenied); XCTAssertEqual(failure.authentication, .unknown)
    }

    func testCancelledInspectionDoesNotConvertCancellationToLoggedOutOrError() async throws {
        let path = executable, runner = FakeRunner()
        let service = MacCodexDiagnostics(runner: runner, locate: { _ in path })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.inspect()
        }
        do { _ = try await task.value; XCTFail("Cancelled probe completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        let calls = await runner.calls; XCTAssertTrue(calls.isEmpty)
    }

    func testExplicitExecutableValidationRejectsDirectoriesMissingFilesAndNetworkURLs() throws {
        XCTAssertThrowsError(try CodexExecutableLocator.validate(URL(fileURLWithPath: "/private/tmp")))
        XCTAssertThrowsError(try CodexExecutableLocator.validate(URL(fileURLWithPath: "/not-present/\(UUID().uuidString)")))
        XCTAssertThrowsError(try CodexExecutableLocator.validate(URL(string: "https://example.invalid/codex")!))
        XCTAssertTrue(try CodexExecutableLocator.validate(URL(fileURLWithPath: "/bin/echo")).isFileURL)
    }

    func testConcurrentProbeIsRejectedAndCancellationReleasesAccountOperationGate() async throws {
        let path = executable, runner = FakeRunner(delay: .milliseconds(100))
        let service = MacCodexDiagnostics(runner: runner, locate: { _ in path })
        let first = Task { try await service.inspect() }
        let deadline = ContinuousClock.now + .seconds(2)
        while await runner.calls.isEmpty && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        do { _ = try await service.inspect(); XCTFail("Overlapping account probe accepted") }
        catch { XCTAssertEqual(error as? CodexDiagnosticIssue, .busy) }
        first.cancel()
        do { _ = try await first.value; XCTFail("Cancelled probe succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
        let retry = try await service.inspect()
        XCTAssertEqual(retry.authentication, .chatGPT)
    }
}
#endif
