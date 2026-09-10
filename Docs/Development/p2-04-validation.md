# P2-04 — Requirement traceability and stale links

Baseline: `9cfe8c0`, 2026-09-10. Implemented and validated.

`ProjectRequirementStore` now prepares and publishes reviewed project-scoped links from automated/manual tests, bugs, documentation and workflows to exact requirement versions/fingerprints. Ordinary creation resolves latest active; historical creation requires an explicit version. Cancel writes nothing. Review publication rechecks both the prior link record and requirement snapshot under the same catalog lock; changed behavior requires fresh review.

Link metadata is stored as human-readable JSON at `Memory/Traceability/<kind>/<readable-id>.json`. It has a revision, title, environment, exact requirement references, archive flag, review reason and update time. Reviewed edits replace the current metadata atomically; requirement history remains immutable. Link subjects are inert local identities, not executable definitions, URLs or proof that a test actually ran. Native link management remains part of P2-10.

Normal `resolveTrace` returns latest-active versions for the linked requirement IDs without rewriting the saved creation links. Explicit linked-version reproduction returns the historical versions and checks fingerprints. Readers validate recorded creation versions before using links. Impact analysis compares each saved version to active behavior in its environment and reports current, potentially stale or unavailable. Drafts do not replace active behavior; retirement and environment exclusion become unavailable. Staleness requests review, not a conclusion that a test is defective.

## Checks

Ignored outputs: `TestResults/p2-04/`.

- `core-initial.log`: 133 existing Core tests passed after implementation compiled.
- `core-tests.log`: 141 passed, including eight traceability tests covering review/cancel/reopen, creation provenance, normal/historical resolution, five subject kinds, archiving, changed-base/replay rejection, scope/environment/retirement, expiry/cancellation/malformed input, forged references and symlink/hardlink rejection.
- `mac-final.log` / `.xcresult`: 395 passed, zero failures/skips, including the normal-resolution fingerprint regression. macOS 26.5.2 (25F84), arm64, Xcode 26.0 (17A324).
- `iphone-final.log` / `.xcresult`: 261 passed, zero failures/skips, on iPhone 16 Pro, iOS 26.0 (23A343), simulator C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE.

Bounds: 64 requirements per record, 16 pending reviews per store, five-minute reviews, revision maximum 1,000,000. Impact scans reject more than 1,000 records or 16 MiB instead of reporting incomplete counts. File reads are bounded and reuse descriptor-based no-follow/single-link protections. No external integrations, company data or provider execution is involved.

Native Mac/iPhone application builds and unit/integration runs passed. Documentation integrity/coverage/link/ignore checks and diff whitespace checks passed. No new UI, release-signing or live-provider run is claimed. Physical display/multi-device acceptance remains deferred.

## Reproduction commands

Run from the repository root with fresh result paths. Existing synthetic SQLite teardown warnings remain outside this task.

```sh
swift test --package-path Packages/AgentDeskCore
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-04/mac-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-04/iphone-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```
