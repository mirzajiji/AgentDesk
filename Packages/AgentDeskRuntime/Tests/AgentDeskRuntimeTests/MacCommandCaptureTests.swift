#if os(macOS)
import Darwin
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class MacCommandCaptureTests: XCTestCase {
    private func run(_ path: String, _ arguments: [String], timeout: Duration = .seconds(3), maximum: Int = 65_536,
                     directory: URL = URL(fileURLWithPath: "/private/tmp"), environment: [String: String] = [:]) async throws -> CLICommandOutput {
        try await MacCommandCapture.run(executable: URL(fileURLWithPath: path), arguments: arguments, directory: directory,
            environment: environment, timeout: timeout, maximumBytes: maximum)
    }

    func testLiteralArgumentsDoNotEvaluateShellMetacharacters() async throws {
        let text = "$(touch should-not-exist); `echo nope` 'quoted'\nsecond line"
        let result = try await run("/usr/bin/printf", ["%s", text])
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), text)
        XCTAssertTrue(result.stderr.isEmpty)
    }

    func testSeparateOutputExitStatusWorkingDirectoryAndExplicitEnvironment() async throws {
        // A fixed synthetic fixture script tests the adapter; product commands never invoke a shell.
        let result = try await run("/bin/sh", ["-c", "printf '%s' \"$AGENTDESK_FIXTURE\"; printf 'synthetic error' >&2; pwd; exit 7"], environment: ["AGENTDESK_FIXTURE": "literal"])
        XCTAssertEqual(result.status, 7)
        XCTAssertEqual(String(decoding: result.stdout, as: UTF8.self), "literal/private/tmp\n")
        XCTAssertEqual(String(decoding: result.stderr, as: UTF8.self), "synthetic error")
        let env = try await run("/usr/bin/env", [], environment: ["AGENTDESK_FIXTURE": "only-this"])
        XCTAssertEqual(String(decoding: env.stdout, as: UTF8.self), "AGENTDESK_FIXTURE=only-this\n")
    }

    func testNonzeroSignalAndMissingExecutableAreReported() async throws {
        let result = try await run("/bin/sh", ["-c", "kill -TERM $$"])
        XCTAssertEqual(result.status, 128 + SIGTERM)
        do { _ = try await run("/not-present/\(UUID().uuidString)", []); XCTFail("Missing process ran") }
        catch { XCTAssertEqual(error as? CodexDiagnosticIssue, .commandFailed) }
    }

    func testCombinedOutputLimitAndTimeoutBoundCommandLifetime() async throws {
        do { _ = try await run("/usr/bin/yes", ["synthetic"], maximum: 100); XCTFail("Unbounded output") }
        catch { XCTAssertEqual(error as? CodexDiagnosticIssue, .outputLimit) }
        let clock = ContinuousClock(), start = clock.now
        do { _ = try await run("/bin/sleep", ["30"], timeout: .milliseconds(100)); XCTFail("Timeout ignored") }
        catch { XCTAssertEqual(error as? CodexDiagnosticIssue, .timedOut) }
        XCTAssertLessThan(clock.now - start, .seconds(2))
    }

    func testCancellationStopsChildAndReturnsPromptly() async throws {
        let clock = ContinuousClock(), start = clock.now
        let task = Task { try await self.run("/bin/sleep", ["30"]) }
        try await Task.sleep(for: .milliseconds(60))
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled process completed") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(clock.now - start, .seconds(2))
        let next = try await run("/usr/bin/printf", ["cleanup-ok"])
        XCTAssertEqual(String(decoding: next.stdout, as: UTF8.self), "cleanup-ok")
    }

    func testDescendantsCannotKeepPipesOpenAfterParentExit() async throws {
        let clock = ContinuousClock(), start = clock.now
        let result = try await run("/bin/sh", ["-c", "/bin/sleep 30 & printf '%s' $!"])
        XCTAssertEqual(result.status, 0)
        XCTAssertLessThan(clock.now - start, .seconds(2))
        let pid = try XCTUnwrap(Int32(String(decoding: result.stdout, as: UTF8.self)))
        // An orphan can briefly remain a zombie until launchd reaps it; it cannot retain the output pipe.
        if kill(pid, 0) == 0 {
            let listing = try await run("/bin/ps", ["-o", "stat=", "-p", String(pid)])
            let state = String(decoding: listing.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            XCTAssertTrue(state.isEmpty || state.hasPrefix("Z"))
        }
    }

    func testNullArgumentsAndInvalidBoundsAreRejectedBeforeSpawn() async throws {
        for (arguments, maximum) in [(["invalid\0argument"], 100), (["valid"], 0)] {
            do { _ = try await run("/bin/echo", arguments, maximum: maximum); XCTFail("Invalid input accepted") }
            catch { XCTAssertEqual(error as? CodexDiagnosticIssue, .commandFailed) }
        }
    }
}
#endif
