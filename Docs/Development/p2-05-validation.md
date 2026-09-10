# P2-05 — Structured project memory, notes and inbox

Baseline: `2af9e4a`, 2026-09-10. Implemented and validated.

`WorkspaceCatalog.memoryStore(in:)` opens project-scoped storage without creating memory records. `capture` can create active notes/inbox items only; it cannot confirm or overwrite knowledge. Preparation/publication reviews all other changes, including confirmation, classification, edits, archive and ignored-inbox disposition. An ignored record must remain an inbox item. Confirmed knowledge needs a classified topic.

Separate JSON files live at `Memory/Knowledge/<UUID>/entry.vN.json` with `current.json`. Each version records scope, identity, revision/ancestry fingerprints, creation/update times, title/body, bounded structured values, topic, kind, disposition, tags, environments, sources and change reason. Source metadata preserves observed/human-statement/interpretation origin, scope, environment/run/agent identity where applicable, inert source reference and capture time. Confirmation does not relabel the original source as observed evidence. Historical revisions remain readable and immutable.

Memory records are separate from requirements, run evidence and bugs. This task supplies real storage/classification services. Native editors and cross-record promotion/attachment flows are P2-10; FTS retrieval/context filtering is P2-06. Runtime adapters still need policy authorization and centralized redaction before persisting imported content. No model/mobile endpoint is exposed.

## Checks

Ignored outputs: `TestResults/p2-05/`.

- `core-initial.log`: 141 existing Core tests passed after implementation compiled.
- `core-tests.log`: 149 ran with one unexpected failure. ISO date encoding dropped source fractional seconds and broke fingerprints on reload.
- `core-fixed.log`: 149 passed, zero failures after preserving full timestamps with default Codable Date encoding. Dates are numeric seconds from Foundation's 2001-01-01 reference epoch; native presentation can format them for people without losing source precision.
- `mac-final.log` / `.xcresult`: 403 passed, zero failures/skips, including the reviewed-archive assertion. macOS 26.5.2 (25F84), arm64, Xcode 26.0 (17A324).
- `iphone-final.log` / `.xcresult`: 269 passed, zero failures/skips, on iPhone 16 Pro, iOS 26.0 (23A343), simulator C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE.

Eight memory tests cover nonauthoritative intake/reviewed promotion, immutable history/reopen, exact source time/structured values, cancel/stale/replay rejection, kind/environment/pagination/disposition filtering, foreign provenance/store/scope rejection, expiry/cancellation/malformed metadata, orphan recovery and tamper/symlink/hardlink rejection.

Limits: 256 KiB per encoded record, 1,024 committed revisions and 16 MiB per history; 32 sources/tags, 128 environment IDs, bounded structured values, 16 pending reviews and five-minute expiry. Listing pages are capped at 100 and default to active records. It is an administrative listing of all kinds; runtime retrieval must explicitly choose authorized classifications. Orphan versions are preserved, skipped during allocation and never silently adopted.

Both native application builds and unit/integration runs passed. Documentation integrity/coverage/link/ignore checks and diff whitespace checks passed. No new native UI, release-signing or live-provider validation is claimed. Physical display and broader iPhone acceptance remain deferred.

## Reproduction commands

Run from the repository root using fresh result paths. Existing synthetic SQLite teardown warnings remain outside this change.

```sh
swift test --package-path Packages/AgentDeskCore
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-05/mac-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-05/iphone-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```
