# P1-07b durable stage/step progress validation

Date: 2026-09-09. Starting commit `0ae202f`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2. Native MacBook Pro arm64, macOS 26.5.2 (25F84). Primary iPhone 16 Pro Simulator, iOS 26.0 (23A343), ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.

## Implementation and exercise

Core now validates operational work plans with stages, child steps, transitions, finite timestamps and deterministic measured units. SQLite schema 3 stores the latest plan and progress snapshots in the same sequenced journal as run states. Runtime commits progress before live delivery and finalizes unfinished work atomically on cancellation/failure. See [execution](../Architecture/execution.md), [persistence](../Architecture/persistence.md) and [events](../Architecture/run-events.md).

The initial Runtime build passed. Core's 8 new tests and persistence's first 5 progress tests passed. Live/replay equality then exposed fractional timestamp rounding when Foundation reference-epoch dates were stored as SQLite Unix-time numbers. Persistence now canonicalizes dates before returning/publishing them, and lifecycle timestamp comparisons use the same precision. Explicit fractional-time regressions cover both downward and upward rounding without weakening equality assertions. The final Runtime suite and native runs pass. This fixes actual event-value divergence rather than hiding it in test tolerances.

```sh
swift test --package-path Packages/AgentDeskCore
swift test --package-path Packages/AgentDeskPersistence
swift test --package-path Packages/AgentDeskRuntime
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' \
  -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-07b/mac-first.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-01/NativeiPhonePrimary \
  -resultBundlePath TestResults/p1-07b/iphone-first.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
python3 Scripts/validate-documentation.py
git diff --check
```

**Passed:** 66 Core, 18 persistence and 16 Runtime package tests; **115 native Mac and 110 iPhone unit/integration executions**, including actual synthetic Keychain checks. Both native targets built and ran successfully. Accepted logs are `core-first.log`, `persistence-final.log`, `runtime-final-2.log`, `mac-first.log` and `iphone-first.log` under ignored `TestResults/p1-07b/`. No source changes followed native acceptance.

## Coverage and remaining boundaries

Tests cover fixed-stage completion/skips; absent percentages for open-ended runs; child/parent ordering; known-unit completion, monotonicity and fixed denominators; terminal preservation/cancellation; duplicate IDs, missing parents, invalid titles and bounded plans; malformed Codable input; maximum-size terminal encoding; schema-1/2 migration preservation; SQL-trigger failure rollback; scope/stale-sequence denial; exact restart replay; live/persisted equality; pause rejection; shutdown; and fractional timestamp round trips. Existing lifecycle overflow, concurrency, cancellation and observer cleanup regressions continue to pass.

Data and operations are synthetic temporary fixtures. Full plans are bounded to 32 stages/128 steps, 160 UTF-8 bytes per title and 128 KiB encoded snapshots. Open-ended plans never expose an overall numeric fraction. Measured units require authoritative deterministic runner input; this task does not add a model-derived progress estimate.

No UI behavior changed, so P1-06b1's nine passing native Mac UI tests remain the latest UI acceptance. Provider execution, policy, output redaction, actual run screens and mobile transport remain pending. The broad device/runtime matrix remains deferred until final full-project acceptance as requested by the user. Unrelated Xcode ordering and historical-handoff wording edits remain outside this feature commit. Documentation integrity/coverage/links/ignore checks and whitespace review pass.
