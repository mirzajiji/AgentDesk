# P2-06b — Selective context and native run integration

Implemented and verified, 2026-09-10. Baseline: `d397ef3`.

Implemented: optional validated agent knowledge preferences (paths, exclusions, literal query, classifications, bounds and explicit traceability subjects), persistence through agent revisions and effective configuration fingerprints, and the native Knowledge editor tab. Legacy profiles keep knowledge retrieval disabled and retain their canonical encoding. Exclusions win, empty include lists match nothing, and notes/inbox require explicit selection.

The authorized pipeline is now connected: native run preparation rebuilds the exact scoped index after policy preflight, resolves authoritative records and current structured relationships, prepares bounded redacted context, exposes the snapshot before approval and revalidates source/trace fingerprints before dispatch. The complete Mac suite, final readable-inspector checks and primary iPhone acceptance passed.

## Validation results

- `swift test --package-path Packages/AgentDeskCore --filter AgentKnowledgeSelectionTests`: three passed. Covers legacy encoding, explicit selection and malformed decoded configuration.
- `swift test --package-path Packages/AgentDeskCore > TestResults/p2-06b/core-selection-final.log 2>&1`: 155 passed, zero failures. Includes stored selection and effective run fingerprint changes.
- Initial native test build (`mac-selection.log` / `.xcresult`) failed because the test class lacked the app editor's main-actor isolation. No test pass is claimed for that attempt. Corrected the test annotation.
- `mac-selection-fixed.xcresult`: authoritative xcresult summary reports three passed, zero failed/skipped. The native Mac app built successfully. Covers editor round-trip, empty/whitespace paths, exclusions and malformed relationship/path input. This is model coverage, not visual UI acceptance.
- `context-tests.log`: seven context-service tests passed (fresh redaction/fingerprints, stale/archived cache, untrusted backend filters and isolation, changed-source validation, whole-packet limits/cancellation and latest-active relationships).
- `binding-tests.log`: five run-boundary tests passed (exact persisted/approved dispatch, denied run/read does not invoke reader, stale approved source blocks provider, missing reader fails closed, native service integration).
- `runtime-initial.log`: eight existing coordinator tests passed.
- `runtime-full.log`: 130 tests executed with one failure in the pre-existing concurrent repository registration test's expected error-type assertion (`ProjectRepositoryRegistryTests.swift:119`). Knowledge tests passed. The unchanged test passed independently (`repository-race-recheck.log`), and the subsequent complete Runtime and native Mac suites passed. This first attempt remains recorded as failed; no repository code/test changes were made.
- `runtime-final.log`: 131 tests passed, zero failures, after adding explicit notes/inbox coverage. The later source-change-during-baseline regression is covered by the complete native Mac suite.
- `mac-final.xcresult`: 433 passed, zero failures/skips, including the final pre-dispatch baseline-change regression and long-context layout check.
- `mac-context-ui.xcresult` and `mac-context-ui-fixed.xcresult`: UI flows reached preparation but failed to open the original disclosure. Replaced it with a dedicated inspector button/sheet.
- `mac-context-inspector.xcresult`: one UI test passed, zero failures/skips. Created/published an active requirement, saved agent include/exclude preferences, relaunched, reopened them, inspected the prepared context and approved a completed synthetic run. The app-window screenshot was inspected; subsequent presentation formatting improves readability without changing the bound packet.
- `mac-readable-inspector.xcresult`: eight passed, zero failures/skips (two presentation tests, five logical layout tests and one native UI flow). The final app-window screenshot was inspected: readable fields, scrolling and the header/Done action remain accessible. Formatting preserves multiline source text, exact large numbers, origin/classification and omission diagnostics.
- `mac-presentation-final.xcresult`: two presentation tests passed after explicitly preserving JSON null as Null (rather than implying missing data). The regression also retains exact large numbers, multiline values and classification.
- `iphone-final.xcresult`: 294 passed, zero failures/skips on iPhone 16 Pro, iOS 26.0 (23A343), local Simulator. The native iOS app built and tests executed.
- Documentation integrity, coverage, links and ignore-rule checks passed; staged whitespace/content review completed before commit.
- `git diff --check` passed at the initial checkpoint.

Native command:

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-06b/mac-selection-fixed.xcresult -only-testing:AgentDeskTests/AgentKnowledgeEditingTests -parallel-testing-enabled NO test
xcrun xcresulttool get test-results summary --path TestResults/p2-06b/mac-selection-fixed.xcresult
```

Platform: macOS 26.5.2 (25F84), arm64, Xcode 26.0. iPhone 16 Pro/iOS 26.0 (23A343) native Simulator validation passed. No new Release or live Codex run is claimed. The full device/display matrix remains deferred to final acceptance.

Final native commands (outputs under ignored `TestResults/p2-06b/`):

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-06b/mac-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-06b/mac-readable-inspector.xcresult -only-testing:AgentDeskTests/KnowledgeContextPresentationTests -only-testing:AgentDeskTests/MacEditorLayoutTests -only-testing:AgentDeskUITests/ProjectRunConsoleUITests/testKnowledgeEditorPersistsAndPreparedContextShowsCurrentRequirement -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-06b/iphone-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-06b/mac-presentation-final.xcresult -only-testing:AgentDeskTests/KnowledgeContextPresentationTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```

Limits: the final source check cannot be atomic with an external process starting; the immutable prepared input still records the exact reviewed bytes. Search limits and context omissions are explicit. Physical displays and the full iOS matrix remain final-product acceptance work. The initial intermittent repository registration test failure is preserved above; no unrelated repository implementation was changed for this task.
