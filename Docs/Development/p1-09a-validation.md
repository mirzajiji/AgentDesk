# P1-09a subprocess streaming and stdin validation

Dates: 2026-09-09–10 (local time; native test results were recorded before midnight). Starting commit `126132d`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2. MacBook Pro arm64, macOS 26.5.2 (25F84). Primary iPhone 16 Pro Simulator, iOS 26.0 (23A343), ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. The final device/OS matrix remains deferred by user instruction.

## Implemented and exercised

The real Mac diagnostics adapter now uses a common internal process transport that feeds bounded stdin while incrementally draining separate stdout and stderr. It emits original byte chunks before exit, preserves split UTF-8, reports exit code separately from a terminating signal and handles early stdin closure without SIGPIPE reaching the host. Callers provide explicit argv, cwd and environment. No shell interpolation, arbitrary XPC command, mobile capability, raw-output persistence or new user permission is introduced.

The transport enforces input/output/argument/environment bounds and deadlines. Cancellation, timeout, output overflow and a throwing consumer terminate the process group, reap its direct child and close owned descriptors. Descendants retaining pipes after parent exit are handled by the existing regression. The synchronous sink must return promptly; the later provider will adapt it to a bounded asynchronous event stream. This is a transport capability, not a complete `ExecutionProvider`, authorization boundary or run coordinator.

Existing 36 Runtime tests passed after replacing the collector implementation. Seven additional real-process tests then passed: large literal stdin with stderr and EOF, output before exit with split UTF-8, early input closure and empty stdin, producer termination/reaping after sink failure, combined output budget, backpressure timeout/cancellation, and invalid inputs/environment plus signal identity. Fixed synthetic shell scripts are fixtures only; prompt bytes are sent through a pipe and never embedded into their command text.

The initial compile required moving `try` over a short-circuit throwing expression. No test acceptance is claimed for that failed build. A subsequent live diagnostic probe initially reused a stale SwiftPM dependency source list and missed the new file; a fresh scratch build discovered it and passed. The product packages and native targets compiled and tested successfully without that probe-cache issue.

## Accepted commands and results

```sh
swift test --package-path Packages/AgentDeskRuntime
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-09a/mac-first.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -only-testing:AgentDeskUITests/AgentDeskUITests/testCodexSettingsHealthDisconnectAndReconnectPersistWithoutSigningOut \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-08b/FilteredIPhone \
  -resultBundlePath TestResults/p1-09a/iphone-first.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
swift run --package-path TestResults/p1-08a/Probe --scratch-path TestResults/p1-09a/ProbeBuild
python3 Scripts/validate-documentation.py
git diff --check
```

**43 Runtime tests, 147 Mac unit/integration tests, one affected Mac Settings UI test and 115 iPhone unit/integration tests pass.** Logs are `runtime-final.log`, `mac-first.log`, `iphone-first.log` and `live-probe-fresh.log`, under ignored `TestResults/p1-09a/`. The native Mac suite includes the real synthetic subprocess and Keychain tests. The UI test verifies the actual signed helper's health/connection controls and persisted disconnect/reconnect without signing out the developer. No UI layout changed, so the previous task's full UI suite and screenshot review remain the baseline.

The read-only installed CLI probe reports version `0.153.4`, authentication `chatGPT`, issue `none` through the new transport. It only inspects version/help/status; no agent run, logout, browser authorization or cached-credential read was performed. Neither account freshness nor plan/usage is inferred.

Mac process code/tests remain excluded from iOS. The tested iPhone artifact contains no XPC service, and the supported Mac-only product/dependency filters remain present. Xcode normalized away an unsupported redundant copy-phase filter from the previous task; this does not change the effective build graph. Existing project formatting, scheme UI metadata and historical-handoff edits remain unstaged. No unrelated files or generated evidence belong in this commit. Documentation integrity, 159-section coverage, local links, ignore rules and diff checks pass. The only source change after accepted native runs was a documentation comment.

P1-09 is split to keep commits focused: this task implements the real reusable process capability, and P1-09b must still add provider-specific requests, event framing/validation, bounded consumers and execution integration. Configuration constraints, policy and the coordinator continue to gate runnable agent tasks.
