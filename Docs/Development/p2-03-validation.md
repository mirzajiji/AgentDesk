# P2-03 — Deterministic requirement validation

Baseline: `8b37b79`, 2026-09-10. Implemented and validated.

Typed bounded predicates live in optional `executableValidationRules`. Omitting that field preserves the canonical encoding of existing requirements and their history fingerprints. Publication and diff review use the existing immutable store. No script, SQL or model execution is involved.

The validator resolves the latest active requirement by default, requires exact project/environment identity and records source, capture time, optional run/agent identity, requirement version/fingerprint, exact rule and observed value. Explicit historical evaluation selects an exact version. Missing evidence, nontraversable paths, incompatible operations and empty rule collections yield unavailable, never a manufactured pass. Missing paths can fail an explicit exists rule; independent comparisons remain unavailable. Report aggregation preserves all individual results and is unavailable if any result is unavailable.

Reports are in-memory evidence and deterministic interpretation. They must cross existing centralized redaction before any later persistence/display adapter. This task does not introduce an external/model/mobile endpoint or collect evidence from company infrastructure.

## Validation records

Ignored outputs are under `TestResults/p2-03/`.

- `core-initial.log`: build failed on omitted unlabeled helper arguments; corrected to explicit nil values.
- `core-tests.log`: 132 tests ran with four failures (three unexpected). Expected JSON null decoded as an absent operand; custom presence-aware decoding corrects this.
- `core-fixed.log`: 132 passed, zero failures. Includes seven validator tests and all Core regressions.
- `mac-final.log` / `.xcresult`: 386 unit/integration tests passed; the history UI case failed after relaunch because the selected row did not open history. Native List selection previously deferred the binding update into a Task. Selection now updates synchronously before asynchronous history loading; a regression checks immediate selection and cancellation.
- `mac-selection.log` / `.xcresult`: 388 passed, zero failures/skips (387 unit/integration tests and one UI case). This includes actual executable-rule editing/review/publication through Advanced JSON and history after relaunch.
- `iphone-final.log` / `.xcresult`: 253 passed, zero failures/skips on iPhone 16 Pro, iOS 26.0 (23A343), simulator C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE.
- Documentation integrity/coverage/link/ignore checks and diff whitespace checks passed.

Use `swift test --package-path Packages/AgentDeskCore` for Core verification. Native tests follow the existing Xcode scheme, Mac and primary iPhone 16 Pro destinations. No physical-display or broader device coverage is claimed.

## Native commands

Mac: macOS 26.5.2 (25F84), arm64, Xcode 26.0 (17A324). Commands build both the application and test targets; result bundles are authoritative. Use a fresh result path when rerunning.

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-03/mac-selection.xcresult -only-testing:AgentDeskTests -only-testing:AgentDeskUITests/RequirementEditorUITests/testReviewedVersionsAdvancedFieldsAndHistorySurviveRelaunch -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-03/iphone-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```

The initial Mac command used the same selection with result path `mac-final.xcresult`. The later run adds the synchronous-selection regression and typed-rule UI coverage. Existing synthetic SQLite teardown warnings remain outside this change. No release-signing, live provider or infrastructure validation is claimed for this task.
