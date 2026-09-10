# P2-01 — Immutable requirement storage and active resolution

Baseline: `11af808`, 2026-09-10. Validation passes. This task implements the scoped local store and resolver; native requirement editing, executable validation rules, traceability, general project memory/retrieval and Bug Registry remain separate Phase 2 tasks.

## Behavior

- Local reviews bind exact content, scope, base version and a short-lived store-owned token. Prepare/cancel do not write authoritative files. Publication rejects changed, expired, reused or foreign reviews.
- Reviewed publication writes a new human-readable JSON version and advances the current pointer. Immutable ancestry is fingerprint-linked. Draft/retired publication is distinct from latest active behavior; historical reproduction is explicit.
- Interrupted pointer updates preserve unused versions. They are skipped when allocating the next version and excluded from committed history rather than silently adopted.
- File-descriptor access, catalog locking, strict IDs, duplicate-key checks, ownership verification and bounds enforce the store boundary. Scoped administrative listing is paginated; optional environment filtering applies to resolution.
- This administrative API is not exposed to Codex or mobile callers. Native review and policy-controlled runtime integration remain explicit later tasks.

See the [storage contract](../Architecture/requirements.md#initial-store-contract-p2-01) for layout, schema, limits and retirement behavior.

## Checks

All outputs are ignored under `TestResults/p2-01/`.

| Record | Result |
| --- | --- |
| `initial-core.log` | New source compiled; existing 108 Core tests passed before requirement regressions were added |
| `core-tests.log` | 118 Core tests passed, including first ten requirement-store scenarios |
| `core-final.log` | 121 Core tests passed after pagination, malformed pointer and size/review-limit coverage |
| `requirement-final.log` | 14 requirement-store tests passed, including concurrent publication |
| `mac-tests.log` / `.xcresult` | 365 native unit/integration tests passed, zero failures/skips; macOS 26.5.2 (25F84), arm64 |
| `iphone-tests.log` / `.xcresult` | 242 tests executed in iPhone 16 Pro Simulator, iOS 26.0 (23A343), zero failures/skips |

The regression suite exercises prepare/cancel without files, exact proposal identity, cross-store and concurrent edits, expiry/clock regression, immutable bytes, readable decimal JSON, reload/history, active/draft/retired transitions, environment filtering, orphan recovery, workspace/project/ownership denial, pointer traversal, historical tampering, symlink/hard-link denial, cancellation, paging, duplicate JSON keys, missing versions and bounded content/review capacity. The orphan test simulates the state after version publication but before pointer publication; it does not claim power-loss hardware testing.

Commands (Xcode 26.0, build 17A324; both native test commands also built their applications):

```sh
swift test --package-path Packages/AgentDeskCore
swift test --package-path Packages/AgentDeskCore --filter ProjectRequirementStoreTests
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-01/mac-tests.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-01/iphone-tests.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```

The trailing Swift Testing runner reports zero tests because these suites use XCTest. The XCTest suite summaries above supply the actual counts.

No new native UI is introduced by this task, so UI behavior is not claimed or retested here. P2-02 owns requirement editing/review UI acceptance. The final native suites include all 14 store regressions alongside the existing app and shared-code suites. Final documentation checks pass 159-section integrity/coverage, 21 required architecture pages and local links. Broader iPhone and physical Mac display matrices remain final-product acceptance work.
