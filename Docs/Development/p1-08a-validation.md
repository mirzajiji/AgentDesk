# P1-08a Codex diagnostics and command adapter validation

Date: 2026-09-09. Starting commit `189bdff`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2. Native MacBook Pro arm64, macOS 26.5.2 (25F84). Primary iPhone 16 Pro Simulator, iOS 26.0 (23A343), ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.

## Installed capability evidence

Read the official [CLI command reference](https://learn.chatgpt.com/docs/developer-commands?surface=cli) and [authentication reference](https://learn.chatgpt.com/docs/auth), then inspected the installed executable's own public help. The executable is `/Applications/ChatGPT.app/Contents/Resources/codex`, version `0.153.4`. Commands inspected were `--version`, `--help`, `login --help`, `logout --help`, `exec --help` and `login status`. Status reported ChatGPT credentials present with exit 0. Raw credential/account output was not displayed or retained.

After implementation compiled, an ignored temporary SwiftPM executable linked the actual Runtime library and called `try await MacCodexDiagnostics().inspect()`. It printed only normalized version/authentication/issue values. Both initial and final probes returned version `0.153.4`, `chatGPT`, and no issue. This was a real installed-provider diagnostic; it did not start an agent run, log out the user, initiate browser login or inspect auth files. A terminal probe does not establish that the sandboxed native app can access the same CLI context; P1-08b must verify that integration.

The probe's source is equivalent to:

```swift
import AgentDeskRuntime
let snapshot = try await MacCodexDiagnostics().inspect()
// Display only snapshot.installation?.version, snapshot.authentication and snapshot.issue.
```

## Tests and regressions

Parser fixtures cover strict version recognition, supported/missing capabilities, positive/negative/unknown authentication, mismatched status codes and unsupported API-key authentication without surfacing its text. Injected service tests cover re-probing before account commands, refresh afterward, missing installation, permission failure, cancellation and concurrent account-operation rejection.

Real synthetic processes verify literal argument delivery, independent stdout/stderr, exact exit/signal status, explicit working directory/environment, output limits, timeout, cancellation, missing executables, invalid input and descendants retaining pipes after parent exit. The first test run exposed inherited signal dispositions from the test host: a synthetic child ignored SIGTERM. The adapter now starts children with default catchable signals and an empty mask. The regression then passed. No live account login/logout is part of ordinary tests.

```sh
swift build --package-path Packages/AgentDeskRuntime
swift run --package-path TestResults/p1-08a/Probe
swift test --package-path Packages/AgentDeskRuntime
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' \
  -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-08a/mac-first.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-01/NativeiPhonePrimary \
  -resultBundlePath TestResults/p1-08a/iphone-first.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
python3 Scripts/validate-documentation.py
git diff --check
```

Final acceptance: **32 Runtime, 131 native Mac and 114 iPhone unit/integration executions pass**, including real synthetic subprocess tests on Mac and Keychain checks on both platforms. The first iPhone invocation built successfully but stalled before any tests started. It was interrupted after about 214 seconds; Xcode also reported an incomplete result bundle during shutdown. The same Simulator was restarted without erasing data and reached a completed boot state. The retry used the same command with `iphone-retry.xcresult`, `-destination-timeout 30`, `-test-timeouts-enabled YES` and `-maximum-test-execution-time-allowance 30`; all 114 tests passed. The interrupted attempt is not counted as coverage.

Accepted logs are `runtime-final-2.log`, `live-probe-final.log`, `mac-first.log` and `iphone-retry.log`. Logs/results are under ignored `TestResults/p1-08a/`; no generated probes or account output belong in Git. Documentation integrity, 159-section coverage, links and ignore checks pass; whitespace/diff review passes. No source changes followed accepted native runs. Unrelated Xcode ordering and historical-handoff wording edits remain unstaged.

## Scope

P1-08 is split into a separately testable real diagnostics library (this task) and native Settings/account integration (P1-08b). No UI behavior changed here. Mac subprocess code is compile-excluded from iOS; shared diagnostic types and parsers compile/test on both platforms. Settings, native app-host CLI access, active-run account handling and browser-flow UI acceptance remain required. There is no new arbitrary shell or mobile execution API, no provider task execution, and no claim about actual subscription plan, token freshness or usage limits.
