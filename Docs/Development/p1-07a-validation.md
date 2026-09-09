# P1-07a persisted lifecycle and state subscriptions validation

Date: 2026-09-09. Starting commit `d98f5b1`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2. Native MacBook Pro arm64, macOS 26.5.2 (25F84). Primary iPhone 16 Pro Simulator, iOS 26.0 (23A343), ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.

## Implementation and package exercise

The new Runtime package implements an exact-project lifecycle service over actual local SQLite persistence. Shared `RunState` defines all allowed transitions, preserving existing serialized state values. Accepted writes precede live delivery. Subscriptions support ordered replay, bounded buffering, explicit overflow recovery and cleanup. See [execution](../Architecture/execution.md) and [event delivery](../Architecture/run-events.md).

`swift build --package-path Packages/AgentDeskRuntime` passed after creating the package's test directory. The initial package manifest had referenced a not-yet-created test directory, which SwiftPM treated as overlapping sources; creating the intended test directory and adding its actual tests resolved that bootstrap error. The first 11 tests exercised real temporary SQLite runs through pause/resume/approval wait/completion, exact replay and failure injection. A twelfth test adds deallocation cleanup; shutdown now reports `closed` distinctly from terminal completion.

```sh
swift test --package-path Packages/AgentDeskRuntime
swift test --package-path Packages/AgentDeskCore
swift package --package-path Packages/AgentDeskPersistence clean
swift test --package-path Packages/AgentDeskPersistence
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' \
  -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-07a/mac-first.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-01/NativeiPhonePrimary \
  -resultBundlePath TestResults/p1-07a/iphone-first.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
```

**Passed:** 12 Runtime, 58 Core and 12 persistence package tests; **97 native Mac and 92 iPhone unit tests**. Both native suites include the Runtime integration cases and actual synthetic Keychain checks. The first persistence package attempt used a stale SwiftPM dependency source list that omitted newer Core files. Cleaning only its generated build output forces correct source discovery; source/configuration data was not deleted. Logs and results are under ignored `TestResults/p1-07a/`.

## Coverage and limitations

The Core tests cover the entire 7×7 transition matrix and state Codable round trips/unknown values. Runtime tests cover live delivery against persisted event equality, restart replay, invalid transitions/terminal reopening, stale sequences, regressing timestamps, explicit overflow and recovery, paged history, invalid cursors, cross-project/workspace denial, per-run observer isolation, failed commits without ghost events, concurrent expected-sequence updates, explicit and task cancellation, cancelled writes, shutdown and deallocation cleanup.

All runs and storage are synthetic; injected SQL triggers target only temporary test databases. There are no live provider calls. No UI behavior changes in this task; the passing P1-06b1 native Mac UI acceptance remains applicable. The app and native test targets link Runtime, so both platform builds compile the new module. Stage/step persistence, measurable progress, Codex processes, policy and execution coordination remain pending and are not claimed as complete.

The project-file commit includes Runtime package/app/test links while preserving the unrelated Xcode ordering change outside the staged feature diff. Generated build/test output, logs and runtime data remain ignored.

Documentation integrity, all 159 sections, subsystem coverage, local links and ignore checks pass. `git diff --check` and project plist validation pass. No source changes followed the accepted native runs.
