#if os(macOS)
import AgentDeskCore
import AgentDeskMCP
import AgentDeskSecurity
import Darwin
import Foundation
import Synchronization
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class MacProcessRunnerTests: XCTestCase {
    private struct Captured: Sendable {
        var stdout = Data(), stderr = Data()
        var chunks = 0
        var first: ContinuousClock.Instant?
    }
    private func collect(_ executable: String, _ arguments: [String] = [], input: Data? = nil,
                         timeout: Duration = .seconds(5), maximum: Int = 2_097_152) async throws -> (MacProcessExit, Captured) {
        let state = Mutex(Captured())
        let exit = try await MacProcessRunner.run(executable: URL(fileURLWithPath: executable), arguments: arguments,
            directory: URL(fileURLWithPath: "/private/tmp"), environment: [:], input: input,
            timeout: timeout, maximumBytes: maximum) { chunk in
            state.withLock {
                $0.chunks += 1
                if $0.first == nil { $0.first = ContinuousClock.now }
                switch chunk.channel {
                case .stdout: $0.stdout.append(chunk.bytes)
                case .stderr: $0.stderr.append(chunk.bytes)
                }
            }
        }
        return (exit, state.withLock { $0 })
    }

    func testLargeLiteralStdinAndEOFRemainExactWhileDrainingBothStreams() async throws {
        let literal = Data((String(repeating: "literal $(touch SHOULD_NOT_EXIST); `echo nope` 🧪\n", count: 6_000) + "\0end").utf8)
        // The script is a fixed synthetic fixture; input is passed through a pipe, never inserted into it.
        let (exit, data) = try await collect("/bin/sh", ["-c", "printf 'before' >&2; /bin/cat; printf 'after' >&2"], input: literal)
        XCTAssertEqual(exit, MacProcessExit(code: 0, signal: nil))
        XCTAssertEqual(data.stdout, literal)
        XCTAssertEqual(String(decoding: data.stderr, as: UTF8.self), "beforeafter")
        XCTAssertGreaterThan(data.chunks, 2)
    }

    func testOutputArrivesBeforeExitAndSplitUTF8RemainsBytes() async throws {
        let (exit, data) = try await collect("/bin/sh", ["-c", #"printf '\342'; /bin/sleep 0.2; printf '\202\254'; /bin/sleep 0.2; printf 'problem' >&2; exit 7"#])
        XCTAssertEqual(exit.code, 7); XCTAssertNil(exit.signal)
        XCTAssertEqual(String(decoding: data.stdout, as: UTF8.self), "€")
        XCTAssertEqual(String(decoding: data.stderr, as: UTF8.self), "problem")
        XCTAssertGreaterThanOrEqual(ContinuousClock.now - (try XCTUnwrap(data.first)), .milliseconds(300))
        XCTAssertGreaterThanOrEqual(data.chunks, 3)
    }

    func testChildClosingStdinEarlyDoesNotSignalOrHangTheHost() async throws {
        let (exit, data) = try await collect("/bin/sh", ["-c", "exec 0<&-; /bin/sleep 0.05; printf 'closed'; exit 9"], input: Data(repeating: 0x61, count: 1_048_576))
        XCTAssertEqual(exit.code, 9)
        XCTAssertEqual(String(decoding: data.stdout, as: UTF8.self), "closed")
        let (emptyExit, empty) = try await collect("/bin/cat", input: Data())
        XCTAssertEqual(emptyExit.code, 0); XCTAssertTrue(empty.stdout.isEmpty)
    }

    func testSinkFailureStopsAndReapsProducer() async throws {
        enum SinkFailure: Error { case full }
        let pid = Mutex<pid_t?>(nil)
        do {
            _ = try await MacProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '%s' $$; /bin/sleep 30"], directory: URL(fileURLWithPath: "/private/tmp"),
                environment: [:], timeout: .seconds(5), maximumBytes: 1_024) { chunk in
                pid.withLock { $0 = Int32(String(decoding: chunk.bytes, as: UTF8.self)) }
                throw SinkFailure.full
            }
            XCTFail("Rejected output was ignored")
        } catch { XCTAssertTrue(error is SinkFailure) }
        let producer = try XCTUnwrap(pid.withLock { $0 })
        XCTAssertEqual(kill(producer, 0), -1); XCTAssertEqual(errno, ESRCH)
    }

    func testCombinedOutputBudgetIsEnforcedBeforeDeliveringExtraBytes() async throws {
        let delivered = Mutex(0)
        do {
            _ = try await MacProcessRunner.run(executable: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "printf '12345'; /bin/sleep 0.05; printf '678901' >&2"], directory: URL(fileURLWithPath: "/private/tmp"),
                environment: [:], timeout: .seconds(2), maximumBytes: 10) { chunk in delivered.withLock { $0 += chunk.bytes.count } }
            XCTFail("Output budget was ignored")
        } catch { XCTAssertEqual(error as? CodexDiagnosticIssue, .outputLimit) }
        XCTAssertEqual(delivered.withLock { $0 }, 5)
    }

    func testInputBackpressureRespectsTimeoutAndCancellation() async throws {
        let input = Data(repeating: 0x61, count: 1_048_576), start = ContinuousClock.now
        do { _ = try await collect("/bin/sleep", ["30"], input: input, timeout: .milliseconds(100)); XCTFail("Blocked stdin ignored timeout") }
        catch { XCTAssertEqual(error as? CodexDiagnosticIssue, .timedOut) }
        let task = Task { try await self.collect("/bin/sleep", ["30"], input: input) }
        try await Task.sleep(for: .milliseconds(50)); task.cancel()
        do { _ = try await task.value; XCTFail("Blocked stdin ignored cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertLessThan(ContinuousClock.now - start, .seconds(2))
    }

    func testMaximumMCPVariableNameReachesTheChildAndLargerNamesAreRejected() async throws {
        let scope = ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()), environment = EnvironmentID()
        let key = String(repeating: "K", count: 128)
        let reference = SecretReference(scope: try SecretScope(workspaceID: scope.workspaceID, projectID: scope.projectID, environmentID: environment))
        let configuration = try MCPStdioConfiguration(scope: scope, environmentID: environment, name: "Synthetic", executable: "/usr/bin/env",
            workingDirectory: nil, secretEnvironment: [key: reference], directoryBase: .registeredRepository)
        XCTAssertEqual(configuration.secretEnvironment.keys.first, key)
        let output = Mutex(Data())
        let result = try await MacProcessRunner.run(executable: URL(fileURLWithPath: configuration.executable), arguments: [],
            directory: URL(fileURLWithPath: "/private/tmp"), environment: [key: "synthetic-value"], timeout: .seconds(5), maximumBytes: 1024) { chunk in
                if case .stdout = chunk.channel { output.withLock { $0.append(chunk.bytes) } }
            }
        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(output.withLock { String(decoding: $0, as: UTF8.self) }, key + "=synthetic-value\n")
        do {
            _ = try await MacProcessRunner.run(executable: URL(fileURLWithPath: "/usr/bin/env"), arguments: [],
                directory: URL(fileURLWithPath: "/private/tmp"), environment: [key + "K": "synthetic-value"], timeout: .seconds(5), maximumBytes: 1024) { _ in XCTFail("Oversized key reached child") }
            XCTFail("Accepted oversized environment key")
        } catch { XCTAssertEqual(error as? CodexDiagnosticIssue, .commandFailed) }
    }
    func testInvalidInputAndEnvironmentFailBeforeLaunchingTheExecutable() async throws {
        for (input, environment, directory) in [
            (Data(repeating: 0, count: 1_048_577), [:], URL(fileURLWithPath: "/private/tmp")),
            (Data(), ["invalid=key": "value"], URL(fileURLWithPath: "/private/tmp")),
            (Data(), ["valid": "null\0value"], URL(fileURLWithPath: "/private/tmp")),
            (Data(), [:], URL(string: "https://example.invalid/private/tmp")!)
        ] {
            do {
                _ = try await MacProcessRunner.run(executable: URL(fileURLWithPath: "/bin/echo"), arguments: ["unexpected launch"],
                    directory: directory, environment: environment, input: input, timeout: .seconds(1), maximumBytes: 100) { _ in XCTFail("Invalid request produced output") }
                XCTFail("Invalid launch was accepted")
            } catch { XCTAssertEqual(error as? CodexDiagnosticIssue, .commandFailed) }
        }
        let (signal, _) = try await collect("/bin/sh", ["-c", "kill -TERM $$"])
        XCTAssertNil(signal.code); XCTAssertEqual(signal.signal, SIGTERM)
    }
}
#endif
