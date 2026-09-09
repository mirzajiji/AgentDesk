#if os(macOS)
import AgentDeskCore
import Darwin
import Foundation
import XCTest
@testable import AgentDeskRuntime

@MainActor
final class CodexCLIProviderTests: XCTestCase {
    private struct Diagnostics: CodexDiagnosing {
        var signedIn = true
        var delay: Duration = .zero
        func inspect(executable: URL?) async throws -> CodexDiagnosticSnapshot {
            try await Task.sleep(for: delay)
            let caps = CodexCapabilities(login: true, logout: true, loginStatus: true, jsonExecution: true, stdinPrompt: true, ephemeralExecution: true, ignoreUserConfig: true)
            return CodexDiagnosticSnapshot(installation: CodexInstallation(executable: executable!, version: "0.153.4", capabilities: caps), authentication: signedIn ? .chatGPT : .signedOut, issue: nil)
        }
        func login(using installation: CodexInstallation) async throws -> CodexDiagnosticSnapshot { try await inspect(executable: installation.executable) }
        func logout(using installation: CodexInstallation) async throws -> CodexDiagnosticSnapshot { try await inspect(executable: installation.executable) }
    }
    private struct Fixture {
        let root: URL
        let script: URL
        var executable: URL { URL(fileURLWithPath: "/usr/bin/perl") }
        var process: FixtureProcess { FixtureProcess(script: script) }
        func remove() { try? FileManager.default.removeItem(at: root) }
    }
    private struct FixtureProcess: CodexProcessExecuting {
        let script: URL
        func run(executable: URL, arguments: [String], directory: URL, environment: [String: String],
                 input: MacProcessInputPipe, timeout: Duration, maximumBytes: Int,
                 output: @Sendable (MacProcessChunk) throws -> Void) async throws -> MacProcessExit {
            // Read a synthetic script with the system interpreter; do not execute writable container files.
            try await MacProcessRunner.run(executable: executable, arguments: [script.path] + arguments,
                directory: directory, environment: environment, interactiveInput: input,
                timeout: timeout, maximumBytes: maximumBytes, output: output)
        }
    }
    private func fixture(_ mode: String = "success") throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("AgentDesk-Provider-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let executable = root.appendingPathComponent("synthetic-codex")
        let source = #"""
        use strict; use warnings; use utf8; use JSON::PP; use Cwd qw(getcwd); use Time::HiRes qw(sleep);
        binmode STDIN, ':raw'; binmode STDOUT, ':raw'; $|=1;
        my $mode=MODE; my $json=JSON::PP->new->utf8;
        sub send_message { print $json->encode($_[0]), "\n"; }
        sub note { send_message({method=>$_[0],params=>$_[1]}); }
        open(my $pidfile,'>','pid.txt') or die; print $pidfile $$; close $pidfile;
        open(my $argsfile,'>','arguments.json') or die; print $argsfile $json->encode(\@ARGV); close $argsfile;
        while (my $line=<STDIN>) {
            my $message=$json->decode($line);
            open(my $log,'>>','requests.jsonl') or die; print $log $json->encode($message),"\n"; close $log;
            my $method=$message->{method}; my $params=$message->{params} // {};
            if ($method eq 'initialize') {
                send_message({id=>$message->{id},result=>{}});
                send_message({id=>$message->{id},result=>{}}) if $mode eq 'duplicate';
            } elsif ($method eq 'thread/start') {
                my $result={cwd=>$params->{cwd},model=>$params->{model} // 'synthetic-default',modelProvider=>'openai',
                    approvalPolicy=>'never',activePermissionProfile=>{id=>$params->{permissions},extends=>undef},
                    runtimeWorkspaceRoots=>$params->{runtimeWorkspaceRoots},sandbox=>{type=>'readOnly',networkAccess=>JSON::PP::false},
                    thread=>{id=>'synthetic-thread',ephemeral=>JSON::PP::true}};
                $result->{activePermissionProfile}->{id}=':danger-full-access' if $mode eq 'permissions';
                $result->{runtimeWorkspaceRoots}=[$params->{cwd}.'-foreign'] if $mode eq 'root';
                $result->{sandbox}->{networkAccess}=JSON::PP::true if $mode eq 'network';
                $result->{approvalPolicy}='on-request' if $mode eq 'approval-policy';
                $result->{thread}->{ephemeral}=JSON::PP::false if $mode eq 'retained';
                send_message({id=>$message->{id},result=>$result});
            } elsif ($method eq 'turn/start') {
                if ($mode eq 'malformed') { print "{bad json}\n"; next; }
                send_message({id=>$message->{id},result=>{turn=>{id=>'synthetic-turn',status=>'inProgress'}}});
                my $thread=$mode eq 'foreign' ? 'foreign-thread' : $params->{threadId};
                note('turn/started',{threadId=>$thread,turn=>{id=>'synthetic-turn',status=>'inProgress'}});
                sleep(30) if $mode eq 'stall';
                if ($mode eq 'approval') { send_message({id=>99,method=>'item/commandExecution/requestApproval',params=>{}}); next; }
                exit(0) if $mode eq 'early';
                my %invalid=('foreign-command'=>'commandExecution',write=>'fileChange','unknown-item'=>'mcpToolCall');
                if (exists $invalid{$mode}) {
                    note('item/started',{threadId=>$thread,turnId=>'synthetic-turn',item=>{id=>'invalid',type=>$invalid{$mode},cwd=>getcwd().'-foreign'}});
                }
                if ($mode eq 'overflow') {
                    for my $n (0..99) {
                        my $item={id=>'command-'.$n,type=>'commandExecution',cwd=>getcwd(),status=>'inProgress'};
                        note('item/started',{threadId=>$thread,turnId=>'synthetic-turn',item=>$item});
                        $item->{status}='completed';
                        note('item/completed',{threadId=>$thread,turnId=>'synthetic-turn',item=>$item});
                    }
                }
                if ($mode ne 'missing') {
                    my $item={id=>'answer',type=>'agentMessage',text=>'synthetic result 🧪',phase=>$mode eq 'commentary' ? 'commentary' : 'final_answer'};
                    $item->{text}='{"ok":true}' if $mode eq 'schema';
                    $item->{text}='{"ok":"unverified"}' if $mode eq 'invalid-schema';
                    note('item/started',{threadId=>$thread,turnId=>'synthetic-turn',item=>$item});
                    note('item/completed',{threadId=>$thread,turnId=>'synthetic-turn',item=>$item});
                }
                note('turn/completed',{threadId=>$thread,turn=>{id=>'synthetic-turn',status=>'completed',error=>undef,items=>[]}});
            }
        }
        exit($mode eq 'exit' ? 7 : 0);
        """#.replacingOccurrences(of: "MODE", with: String(reflecting: mode))
        try Data(source.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: executable.path)
        return Fixture(root: root, script: executable)
    }
    private func request(_ scope: ProjectScope, timeout: Duration = .seconds(5)) -> ExecutionRequest {
        ExecutionRequest(identity: ExecutionIdentity(scope: scope, runID: RunID(), agentID: AgentID(), environmentID: EnvironmentID()),
                         instructions: "Use synthetic evidence only.", task: "literal $(touch NO); `echo nope`\n🧪", model: nil, timeout: timeout, maximumActivities: 200)
    }
    private func collect(_ execution: ProviderExecution) async throws -> [ExecutionProviderEvent] {
        defer { execution.cancel() }
        var events: [ExecutionProviderEvent] = []
        for try await event in execution.events { events.append(event) }
        return events
    }
    private var scope: ProjectScope { ProjectScope(workspaceID: WorkspaceID(), projectID: ProjectID()) }

    func testVerifiedHandshakeLiteralTaskAndCompletedResultAreBoundToExactIdentity() async throws {
        let fixture = try fixture(); defer { fixture.remove() }
        let scope = scope, request = request(scope)
        let provider = try CodexCLIProvider(scope: scope, directory: fixture.root, executable: fixture.executable, diagnostics: Diagnostics(), process: fixture.process)
        let events = try await collect(provider.start(request))
        XCTAssertEqual(events.map(\.sequence), [1,2,3]); XCTAssertTrue(events.allSatisfy { $0.identity == request.identity })
        XCTAssertEqual(events.last?.payload, .completed(text: "synthetic result 🧪"))
        let lines = try String(contentsOf: fixture.root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
        let messages = try lines.map { try CodexJSONValue.decodeMessage(Data($0.utf8)) }
        let turn = try XCTUnwrap(messages.first { $0["method"]?.string == "turn/start" })
        XCTAssertEqual(turn["params"]?["input"]?.array?.first?["text"]?.string, request.task)
        let thread = try XCTUnwrap(messages.first { $0["method"]?.string == "thread/start" })
        XCTAssertEqual(thread["params"]?["runtimeWorkspaceRoots"]?.array, [.string(fixture.root.resolvingSymlinksInPath().path)])
        XCTAssertEqual(thread["params"]?["selectedCapabilityRoots"]?.array, [])
        let profile = try XCTUnwrap(thread["params"]?["permissions"]?.string)
        let arguments = try JSONDecoder().decode([String].self, from: Data(contentsOf: fixture.root.appendingPathComponent("arguments.json")))
        XCTAssertTrue(arguments.contains { $0.hasPrefix("permissions={") && $0.contains(profile) && $0.contains("\":minimal\"=\"read\"") })
        XCTAssertTrue(arguments.contains("default_permissions=\"\(profile)\""))
        XCTAssertEqual(thread["params"]?["config"]?["features.hooks"]?.bool, false)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("NO").path))
        _ = provider // Keep the execution authority alive until its stream is consumed.
    }

    func testUnverifiedPermissionsOrRootsNeverReceiveTheTask() async throws {
        for mode in ["permissions", "root", "network", "approval-policy", "retained"] {
            let fixture = try fixture(mode); defer { fixture.remove() }
            let scope = scope
            let provider = try CodexCLIProvider(scope: scope, directory: fixture.root, executable: fixture.executable, diagnostics: Diagnostics(), process: fixture.process)
            do { _ = try await collect(provider.start(request(scope))); XCTFail("Unverified configuration ran") }
            catch { XCTAssertEqual(error as? ExecutionProviderError, .unverifiedPermissions) }
            let transcript = try String(contentsOf: fixture.root.appendingPathComponent("requests.jsonl"), encoding: .utf8)
            XCTAssertFalse(transcript.contains("turn/start"))
        }
    }

    func testMalformedForeignDuplicateApprovalAndIncompleteEventsFailClosed() async throws {
        let cases: [(String,ExecutionProviderError)] = [("malformed",.invalidProtocol),("foreign",.scopeMismatch),("duplicate",.invalidProtocol),("approval",.unexpectedApproval),("early",.incompleteResult),("missing",.incompleteResult),("exit",.processFailed),("foreign-command",.scopeMismatch),("write",.unverifiedPermissions),("unknown-item",.invalidProtocol),("commentary",.incompleteResult)]
        for (mode, expected) in cases {
            let fixture = try fixture(mode); defer { fixture.remove() }
            let scope = scope
            let provider = try CodexCLIProvider(scope: scope, directory: fixture.root, executable: fixture.executable, diagnostics: Diagnostics(), process: fixture.process)
            var terminal = false
            do {
                let execution = try await provider.start(request(scope)); defer { execution.cancel() }
                for try await event in execution.events { if case .completed = event.payload { terminal = true } }
                XCTFail("Invalid provider ended successfully: \(mode)")
            } catch { XCTAssertEqual(error as? ExecutionProviderError, expected, mode) }
            XCTAssertFalse(terminal, mode)
        }
    }

    func testSlowConsumerOverflowIsExplicitAndStopsProducer() async throws {
        let fixture = try fixture("overflow"); defer { fixture.remove() }
        let scope = scope
        let provider = try CodexCLIProvider(scope: scope, directory: fixture.root, executable: fixture.executable, capacity: 1, diagnostics: Diagnostics(), process: fixture.process)
        let execution = try await provider.start(request(scope))
        // Wait for the producer to exit without consuming, independent of interpreter startup speed.
        let deadline = ContinuousClock.now + .seconds(4)
        while ContinuousClock.now < deadline {
            if let text = try? String(contentsOf: fixture.root.appendingPathComponent("pid.txt"), encoding: .utf8),
               let pid = Int32(text), kill(pid, 0) == -1, errno == ESRCH { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        do { _ = try await collect(execution); XCTFail("Consumer overflow was hidden") }
        catch { XCTAssertEqual(error as? ExecutionProviderError, .consumerOverflow) }
        let pid = try XCTUnwrap(Int32(String(contentsOf: fixture.root.appendingPathComponent("pid.txt"), encoding: .utf8)))
        XCTAssertEqual(kill(pid, 0), -1); XCTAssertEqual(errno, ESRCH)
    }

    func testTimeoutCancellationAndBusyGuardReleaseTheProcess() async throws {
        let fixture = try fixture("stall"); defer { fixture.remove() }
        let scope = scope
        let provider = try CodexCLIProvider(scope: scope, directory: fixture.root, executable: fixture.executable, diagnostics: Diagnostics(), process: fixture.process)
        do { _ = try await collect(provider.start(request(scope, timeout: .milliseconds(150)))); XCTFail("Timeout ignored") }
        catch { XCTAssertEqual(error as? ExecutionProviderError, .timedOut) }
        // Completion delivery precedes the actor's cleanup message by a scheduling boundary.
        try await Task.sleep(for: .milliseconds(30))
        let execution = try await provider.start(request(scope))
        do { _ = try await provider.start(request(scope)); XCTFail("Overlapping process allowed") }
        catch { XCTAssertEqual(error as? ExecutionProviderError, .busy) }
        execution.cancel()
        do { _ = try await collect(execution); XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    func testDeadlineIncludesDiagnosticsAndCancelsTheProbeBeforeLaunch() async throws {
        let fixture = try fixture(); defer { fixture.remove() }
        let scope = scope
        let provider = try CodexCLIProvider(scope: scope, directory: fixture.root, executable: fixture.executable, diagnostics: Diagnostics(delay: .seconds(5)), process: fixture.process)
        let started = ContinuousClock.now
        do { _ = try await provider.start(request(scope, timeout: .milliseconds(50))); XCTFail("Diagnostics escaped the deadline") }
        catch { XCTAssertEqual(error as? ExecutionProviderError, .timedOut) }
        XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("pid.txt").path))
    }

    func testSchemaReachesCLIAndInvalidFinalOutputNeverCompletes() async throws {
        for mode in ["schema", "invalid-schema", "success"] {
            let fixture = try fixture(mode); defer { fixture.remove() }
            let scope = scope, base = request(scope)
            let schema = OutputSchema.object(["ok": .boolean])
            let configured = ExecutionRequest(identity: base.identity, instructions: base.instructions, task: base.task,
                model: base.model, timeout: base.timeout, maximumActivities: base.maximumActivities, outputSchema: schema)
            let provider = try CodexCLIProvider(scope: scope, directory: fixture.root, executable: fixture.executable, diagnostics: Diagnostics(), process: fixture.process)
            var completed = false
            do {
                let execution = try await provider.start(configured); defer { execution.cancel() }
                for try await event in execution.events { if case .completed(let text) = event.payload { completed = true; XCTAssertEqual(text, #"{"ok":true}"#) } }
                XCTAssertEqual(mode, "schema")
            } catch { XCTAssertNotEqual(mode, "schema"); XCTAssertEqual(error as? ExecutionProviderError, .invalidOutput) }
            XCTAssertEqual(completed, mode == "schema")
            let lines = try String(contentsOf: fixture.root.appendingPathComponent("requests.jsonl"), encoding: .utf8).split(separator: "\n")
            let messages = try lines.map { try CodexJSONValue.decodeMessage(Data($0.utf8)) }
            let turn = try XCTUnwrap(messages.first { $0["method"]?.string == "turn/start" })
            XCTAssertEqual(turn["params"]?["outputSchema"], try JSONDecoder().decode(CodexJSONValue.self, from: schema.jsonData()))
        }
    }
    func testConfiguredOutputByteLimitFailsBeforeCompletion() async throws {
        let fixture = try fixture(); defer { fixture.remove() }
        let scope = scope, base = request(scope)
        let configured = ExecutionRequest(identity: base.identity, instructions: base.instructions, task: base.task,
            model: base.model, timeout: base.timeout, maximumActivities: base.maximumActivities, maximumOutputBytes: 4)
        let provider = try CodexCLIProvider(scope: scope, directory: fixture.root, executable: fixture.executable, diagnostics: Diagnostics(), process: fixture.process)
        do { _ = try await collect(provider.start(configured)); XCTFail("Output limit ignored") }
        catch { XCTAssertEqual(error as? ExecutionProviderError, .outputLimit) }
    }

    func testScopeAuthenticationAndChangedRootAreRejectedBeforeLaunch() async throws {
        let fixture = try fixture(); defer { fixture.remove() }
        let scope = scope
        let provider = try CodexCLIProvider(scope: scope, directory: fixture.root, executable: fixture.executable, diagnostics: Diagnostics(), process: fixture.process)
        do { _ = try await provider.start(request(self.scope)); XCTFail("Foreign scope accepted") }
        catch { XCTAssertEqual(error as? ExecutionProviderError, .scopeMismatch) }
        let signedOut = try CodexCLIProvider(scope: scope, directory: fixture.root, executable: fixture.executable, diagnostics: Diagnostics(signedIn: false), process: fixture.process)
        do { _ = try await signedOut.start(request(scope)); XCTFail("Signed-out provider started") }
        catch { XCTAssertEqual(error as? ExecutionProviderError, .unauthenticated) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("requests.jsonl").path))
        let renamed = fixture.root.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: fixture.root, to: renamed)
        defer { try? FileManager.default.removeItem(at: renamed) }
        try FileManager.default.createDirectory(at: fixture.root, withIntermediateDirectories: false)
        do { _ = try await provider.start(request(scope)); XCTFail("Replaced root accepted") }
        catch { XCTAssertEqual(error as? ExecutionProviderError, .scopeMismatch) }
    }
}
#endif
