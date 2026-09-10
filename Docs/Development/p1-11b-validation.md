# P1-11b signed Mac execution bridge and native run service

Date: 2026-09-10. Starting commit `0c2f111`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, macOS 26.5.2 (25F84), arm64. Primary Simulator: AgentDesk iPhone 16 Pro, iOS 26.0 (23A343), `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. Broader device/minimum-runtime acceptance remains deferred.

## Scope

The signed app-private helper now transports a typed, bounded read-only run request and sequential provider observations. The app's internal provider adapter and helper independently bind the physical directory and exact execution identity; the helper always uses the existing restricted Codex provider. There is no generic shell, arbitrary argument list, mobile endpoint, new credential source or entitlement change. The existing user approval covers the signed helper running prepared Codex commands as the local macOS user.

A connection-scoped helper session rejects replay/substitution, bounds queued event bytes/count, validates provider events and waits for clean termination. Both sides enforce the existing exact bundle/team signing requirements. Connection loss/cancellation shuts down the provider; a separate helper-side project lease remains held until provider cleanup finishes, including when the main process loses its own lease. Its fixed private lock directory is `~/Library/Application Support/AgentDeskCodexHost/`; lock files remain after release to preserve locking semantics.

The native service exposes opaque preparation/execution capabilities, explicit local review, policy installation, scoped progress/history and sanitized evidence reads. It binds one agent/environment, creates separate temporary local reviewer and agent authorities, and requires shutdown before replacing the project owner. UI/wire consumers never receive raw provider output, an execution constructor or helper configuration authority. The trusted configuration owner must propagate policy edits; provider text cannot approve or renew its session. Repository access grants must remain held by the native caller until shutdown. Native run UI remains P1-13.

## Accepted results

Ten new Runtime tests pass: helper wire/loopback lifecycle and the native service's approval, scoped evidence, policy replacement and shutdown paths. The first compile corrected a throwing fixture expression and a repository initializer label. The helper overflow test also verifies explicit failure and provider release after a slow consumer fills its 64-event queue.

The actual native signed XPC integration test passes without a CLI account or model call. It requires the helper to acknowledge the exact synthetic run identity/resource before returning a typed unavailable-executable result. A transport connection failure does not satisfy the test.

The **native live smoke probe passes** through the actual signed helper (8.206 seconds): exact synthetic output, an observed completed command step, unchanged source and persisted completion are verified. Its first native build required an explicit persistence-module import and made no model call. **106 Runtime tests, 278 affected native Mac unit/integration tests and 215 native iPhone tests pass**. The account-independent signed XPC test is included in the 278 count; its earlier focused run is not added again. The successful explicit live probe is one separate native execution. The normal signed Mac build passes, and both app/helper signatures and existing entitlement separation are verified. The unchanged interactive Mac Keychain/UI checks remain unavailable as documented in P1-12c/P1-11a and are not counted as passing here.

## Artifacts

Ignored output is under `TestResults/p1-11b/`. `mac-xpc.log` / `mac-xpc.xcresult` record the real signed connection test. `NativeCodexLiveProbeTests.swift` is a synthetic, explicit live probe copied temporarily into the native test target for the selected run; it is removed from the source tree afterward, so ordinary tests never require an account or model call. Its source and result remain in ignored validation output.

The live probe uses `/Applications/ChatGPT.app/Contents/Resources/codex` and the developer's supported existing CLI login. It does not log out, extract credentials or change CLI account configuration. Only a synthetic `evidence.txt` under a fresh authorized directory is requested; success requires exact final content, a completed observed command step, unchanged source, durable final state and no invented progress percentage.


## Reproduction commands

```sh
swift test --package-path Packages/AgentDeskRuntime --scratch-path TestResults/p1-11b/RuntimeBuild
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-11b/mac-unit.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -skip-testing:AgentDeskTests/KeychainIntegrationTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p1-11b/iphone.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build
codesign --verify --strict --verbose=2 TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app
codesign --verify --strict --verbose=2 TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app/Contents/XPCServices/AgentDeskCodexHost.xpc
python3 Scripts/validate-documentation.py
git diff --check
```

The live-only invocation, with the retained probe temporarily copied into `AgentDeskTests/`, uses the Mac command above with `-only-testing:AgentDeskTests/NativeCodexLiveProbeTests`, a 120-second allowance and `mac-live-final.xcresult`. The failed compile remains in `mac-live.log` / `mac-live.xcresult`; accepted output is `mac-live-final.log` / `mac-live-final.xcresult`. Full-suite logs are `runtime.log`, `mac-unit.log`, `iphone.log` and `normal-mac.log`. No live probe remains in tracked application/test sources, and no live account is needed for ordinary tests.

Documentation integrity/159-section coverage, local links, ignore rules and diff checks pass. Review excludes preexisting Xcode normalization, personal scheme metadata and historical handoff wording. Personal GitHub origin and effective personal author/committer are checked again before commit/push. No test output, company data or credential material is staged.
