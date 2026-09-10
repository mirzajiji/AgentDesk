# P2-06a — Scoped rebuildable knowledge index

Baseline: `f587083`, 2026-09-10. Implemented and validated. P2-06 is split into index storage/search (this task) and authoritative context/run integration (P2-06b), each with its own commit gate.

Operational migration 6 adds a SQLite FTS5 cache and generation table. JSON memory and requirement files remain authoritative. Index instances bind one project/environment; rebuild replaces only that projection transactionally. Collection reads active memory and resolves latest-active requirements, preserving the exact source revision/fingerprint. Failed collection, scope checks, redaction or stale-generation checks leave the old projection intact.

Memory optionally declares a logical `knowledgePath`; omission preserves existing canonical JSON/fingerprints. Defaults group topics under architecture, api, qa, behavior, overview, terminology, docs or the unclassified kind. These are metadata paths, never filesystem access. Include/exclude filters support exact paths, `prefix/**` and `**`; exclusion wins and comparisons use case-sensitive segment boundaries. Invalid/traversing/absolute paths are rejected.

Every title/body is centrally redacted before SQLite insertion. Logical paths that would require redaction are rejected. Searches default to requirements and confirmed memory; notes/inbox require explicit classification selection. Plain query terms are quoted literal FTS terms combined with AND, not user SQL or arbitrary FTS expressions. Results use deterministic path/source ordering. Cursor pagination binds query, filters, scope, environment and generation; rebuilds invalidate old cursors.

## Evidence

Ignored outputs: `TestResults/p2-06a/`.

- `persistence-initial.log`: 41 existing persistence tests passed after migration/index compilation.
- `persistence-tests.log`: 47 passed, including six FTS integration tests.
- `persistence-final.log`: 47 passed after adding query-bound pagination, case-sensitive filtering and same-workspace sibling-project coverage.
- `mac-final.log` / `.xcresult`: 411 passed, zero failures/skips, including two Core source/path regressions. macOS 26.5.2 (25F84), arm64, Xcode 26.0 (17A324).
- `iphone-final.log` / `.xcresult`: 277 passed, zero failures/skips, on iPhone 16 Pro, iOS 26.0 (23A343), simulator C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE.
- Native app builds, documentation integrity/coverage/link/ignore checks and diff whitespace checks passed.

Tests cover actual FTS matching/reopen, default classification, empty/unbuilt distinction, case-sensitive includes/excludes, sibling-prefix traversal denial, workspace/project/environment isolation, archived-source removal, atomic stale rebuild rejection, pre-persistence redaction (including database/sidecar bytes), literal queries, bounded pagination, changed-query/rebuild cursor rejection, duplicate inputs and cancellation.

Bounds: 1,000 documents and 16 MiB per projection rebuild, 256 KiB per document, 16 query terms/1 KiB input, 32 includes and 32 excludes, pages of at most 100. The database migration preserves existing operational history and fails rather than resetting unsupported schemas. Existing migration expectations now target version 6.

The cache is not dispatch authority. Revalidation, relationship context, agent selectors, bounded prompt assembly and native run preview/dispatch binding remain P2-06b. No search content is automatically added to a run in this commit. Native management remains P2-10. No physical display/multi-device/live-provider coverage is claimed.

## Reproduction commands

Run from the repository root using fresh result paths. Existing synthetic SQLite teardown warnings remain outside this task.

```sh
swift test --package-path Packages/AgentDeskPersistence
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-06a/mac-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-06a/iphone-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```
