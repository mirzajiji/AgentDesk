# P2-10c — Native traceability and impact

Implemented and validated, 2026-09-11.

## Behavior and authority

Project actions and command routing open a scoped native traceability browser. Search, kind/environment/archive filters and identity-based pagination read validated current records. The editor reviews exact links, supports latest-active or explicit historical versions, and rejects stale or foreign proposals. The inspector distinguishes recorded content from current active behavior, shows stale/unavailable status and navigates impact links.

Bug Registry requirement associations are included separately from standalone traces. Direct requirement-ID inspection works with no standalone records. Review Bug opens the scoped editor; ordinary edits preserve exact references, while explicit association edits can resolve current/historical versions or clear references. Coverage subjects are inert manual/automated test identities. No link claims execution or success. Each impact query is locked; the two reports are not claimed to be a combined transactional snapshot. Immediate cancellation, bounded scanning and ownership/integrity checks fail closed.

## Final evidence

Ignored outputs: `TestResults/p2-10c/`.

- `core-final.log`: 196 Core tests passed, zero failures. Includes trace browse/filter/paging, corrupt-reference rejection, current/stale/retired Bug Registry impact, scope denial, archive exclusion and cancellation.
- `bug-links-models-fixed.xcresult`: 12 native model tests passed, zero failures/skips. Exact reviewed publication, cancellation, stale latest-version rejection, explicit history, preserved/refreshed/cleared bug associations and Bug Registry-only impact.
- `coverage-ui.xcresult`: its model/layout portion passed 20 tests. Its UI portion failed because a broad selector matched a background detail field; corrected in the integrated run below.
- `trace-ui.xcresult`: native publication, newer requirement/stale status, historical inspection and archive filtering passed. Review and historical-inspection app-window screenshots exported and visually inspected.
- `coverage-integrated-ui.xcresult`: native requirement association and coverage review, relaunch persistence, direct requirement impact and scoped bug-editor navigation passed. Persisted-association app-window screenshot exported and visually inspected.
- `iphone.xcresult`: 337 tests passed, zero failures/skips, on AgentDesk iPhone 16 Pro (`C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`), iOS 26.0 (23A343). This was an actual native Simulator test run.
- `mac-final.xcresult`: 22 native Mac model, command and layout tests passed, zero failures/skips, after the last shared cancellation check.

Mac platform: macOS 26.5.2 (25F84), arm64, Xcode 26.0 (17A324). Multi-device and physical display acceptance remain deferred as requested. The existing SQLite fixture teardown warnings (unlinking temporary databases while a connection remains open) recur during the iPhone suite; they are not claimed resolved. AppIntents metadata extraction also warns that no framework dependency exists. Neither changed the passing test result.

## Earlier checks and corrections

`trace-browse.log` passed 10 Core traceability tests. Early native builds corrected the required `.historical(version:)` label and a missing Security import. `models-fixed`, `editor-models`, `editor-view-fixed`, `browser-build` and `layouts` bundles record incremental passing model/layout runs. `bug-links-models.xcresult` initially failed to compile because a new test omitted `expectedVersion: nil`; the corrected run passed. `bug-impact.log` was sandbox-blocked on the compiler cache; the authorized rerun and retirement extension passed all 17 Bug Registry tests. The complete final Core run supersedes those narrow checks.

The Requirements padding recheck passed all four states, with strict 12–36-point header insets and inspected app-window screenshots. Its display-size test adjustment was separately committed and pushed as `c135baf`; see [P2-03a](p2-03a-validation.md). The initial width assumptions and their failures remain documented there.

Documentation integrity, section coverage, local links, ignore rules and diff checks passed. The task diff was reviewed; unrelated Xcode normalization, user scheme state and the existing continuation note were excluded.

## Commands

```sh
swift test --package-path Packages/AgentDeskCore
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10c/mac-final.xcresult -only-testing:AgentDeskTests/NativeTraceabilityModelTests -only-testing:AgentDeskTests/NativeBugModelTests -only-testing:AgentDeskTests/NativeCommandCatalogTests -only-testing:AgentDeskTests/MacEditorLayoutTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10c/trace-ui.xcresult -only-testing:AgentDeskUITests/RequirementEditorUITests/testTraceabilityReviewCurrentHistoricalAndArchive -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10c/coverage-integrated-ui.xcresult -only-testing:AgentDeskUITests/BugEditorUITests/testCoverageSubjectReviewPersistsWithoutClaimingExecution -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-10c/iphone.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```
