# P2-07 — Persistent Bug Registry and manual ticket associations

Implemented and verified, 2026-09-10. Baseline: `25c67e7`.

The project-bound registry stores reviewed immutable bug versions, manual ticket keys/URLs and link/unlink history, exact requirement/evidence references, classified observations and bug/test relationships. Requirement validation and bug publication share the catalog root lock. Missing targets, directed cycles, stale reviews, expired/foreign/replayed tokens, invalid links and unsafe files fail closed. No external ticket creation or native management UI is claimed; those belong to later tasks.

## Validation results

- `domain-tests.log`: six domain tests passed (manual links and safe URLs, reported/observed/blocked distinctions, scope/environment, relationships and exact reference/date encoding).
- `store-build.log`: compiled registry files/service and six domain tests passed.
- `store-tests.log`: first six persistence tests passed (cancel/relink/reopen, latest/historical requirement references, isolation/cycles, stale/replayed/expired reviews, orphan/tampered history, scoped paging).
- `core-final.log`: all 169 Core tests passed, zero failures. Adds symlink/hard-link defenses and store-bound review/capacity/cancellation coverage.
- `mac-final.xcresult`: 449 passed, zero failures/skips. Native macOS app built and unit/integration tests executed.
- `iphone-final.xcresult`: 308 passed, zero failures/skips. Native iOS app built and tests executed on the local iPhone 16 Pro Simulator, iOS 26.0 (23A343).
- Result totals/device details were read from `xcresulttool get test-results summary`, not inferred from a build headline.
- Documentation integrity, section coverage, links, ignore rules and staged diff/content checks passed.

Commands:

```sh
swift test --package-path Packages/AgentDeskCore --filter BugRecordTests
swift test --package-path Packages/AgentDeskCore --filter ProjectBugStoreTests
swift test --package-path Packages/AgentDeskCore
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-07/mac-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-07/iphone-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```

Outputs are ignored under `TestResults/p2-07/`. This administrative storage service does not prove that referenced operational artifacts or external tickets exist. Runtime consumers must authorize and verify evidence; automated intake must redact before persistence. Source declarations and blocked/unverified findings remain explicit.

Platform: macOS 26.5.2 (25F84), arm64, Xcode 26.0. No new UI interaction, Release, live Codex or external Jira test is claimed. Full physical display and multi-device iOS acceptance remain deferred to the full-product gate.
