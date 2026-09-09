#if os(macOS)
import Foundation
import Security
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class CodexHostContractTests: XCTestCase {
    private actor Probe: CodexDiagnosing {
        var calls = 0
        var cancelled = false
        let delay: Duration
        init(delay: Duration = .zero) { self.delay = delay }
        func inspect(executable: URL?) async throws -> CodexDiagnosticSnapshot {
            calls += 1
            do { if delay > .zero { try await Task.sleep(for: delay) } }
            catch { cancelled = true; throw error }
            return CodexDiagnosticSnapshot(installation: nil, authentication: .signedOut, issue: nil)
        }
        func login(using installation: CodexInstallation) async throws -> CodexDiagnosticSnapshot { try await inspect(executable: installation.executable) }
        func logout(using installation: CodexInstallation) async throws -> CodexDiagnosticSnapshot { try await inspect(executable: installation.executable) }
    }
    private func decode(_ data: Data) throws -> CodexDiagnosticSnapshot { try JSONDecoder().decode(CodexDiagnosticSnapshot.self, from: data) }

    func testTypedRequestRoundTripAndNormalizedResponse() async throws {
        let probe = Probe()
        let data = try JSONEncoder().encode(CodexHostRequest(operation: .inspect, executable: URL(fileURLWithPath: "/synthetic/codex")))
        let result = try decode(await CodexHostContract.respond(to: data, using: probe))
        XCTAssertEqual(result.authentication, .signedOut); XCTAssertNil(result.issue)
        let calls = await probe.calls; XCTAssertEqual(calls, 1)
    }

    func testMalformedOversizedAndUnsupportedRequestsNeverReachCodex() async throws {
        let probe = Probe()
        let requests = [Data("not-json".utf8), Data(repeating: 32, count: CodexHostContract.maximumMessageBytes + 1),
            Data("{\"operation\":\"shell\",\"executable\":\"file:///bin/sh\"}".utf8),
            try JSONEncoder().encode(CodexHostRequest(operation: .login)),
            try JSONEncoder().encode(CodexHostRequest(operation: .inspect, executable: URL(string: "https://example.invalid/codex")!))]
        for request in requests {
            let result = try decode(await CodexHostContract.respond(to: request, using: probe))
            XCTAssertNotNil(result.issue); XCTAssertEqual(result.authentication, .unknown)
        }
        let calls = await probe.calls; XCTAssertEqual(calls, 0)
    }

    func testSessionInvalidationCancelsWorkAndRejectsLateRequests() async throws {
        let probe = Probe(delay: .seconds(30)), session = CodexHostSession(service: probe)
        let request = try JSONEncoder().encode(CodexHostRequest(operation: .inspect))
        let first = Task { await session.perform(request) }
        let deadline = ContinuousClock.now + .seconds(2)
        while await probe.calls == 0 && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        let concurrent = try decode(await session.perform(request))
        XCTAssertEqual(concurrent.issue, .busy)
        await session.invalidate()
        let interrupted = try decode(await first.value)
        XCTAssertNotNil(interrupted.issue)
        let cancelled = await probe.cancelled; XCTAssertTrue(cancelled)
        let late = try decode(await session.perform(request)); XCTAssertEqual(late.issue, .busy)
        let calls = await probe.calls; XCTAssertEqual(calls, 1)
    }

    func testBothPeerRequirementsAreValidAndPinDifferentBundleIdentities() {
        for expression in [CodexHostContract.clientRequirement, CodexHostContract.serviceRequirement] {
            var requirement: SecRequirement?
            XCTAssertEqual(SecRequirementCreateWithString(expression as CFString, SecCSFlags(), &requirement), errSecSuccess)
            XCTAssertNotNil(requirement)
            XCTAssertTrue(expression.contains("3R9673A8NL")); XCTAssertTrue(expression.contains("anchor apple generic"))
        }
        XCTAssertNotEqual(CodexHostContract.clientRequirement, CodexHostContract.serviceRequirement)
    }
}
#endif
