# P2-11 — Phase 2 acceptance

Status: complete for the Phase 2 development scope, 2026-09-11. Full-product acceptance and phases 3–6 remain outstanding. Acceptance combines the broad platform runs with focused post-fix checks; it is not a claim that every historical run passed.

Scope is the twelve Phase 2 requirements in architecture section 110, together with the native acceptance scenarios in the task ledger. Later integration phases remain outstanding.

| Requirement | Implementation and acceptance evidence |
| --- | --- |
| Structured memory | P2-05 and P2-10a; ProjectMemoryStoreTests and native reviewed memory flow |
| Requirement storage | P2-01; ProjectRequirementStoreTests |
| Requirement versioning | Immutable publications, orphan/history checks, RequirementEditorUITests |
| Current requirement resolver | RequirementValidatorTests latest-active/historical/retirement test |
| Validation rules | RequirementValidatorTests exact predicates, missing/blocked evidence, scope and malformed input |
| Requirement diff | RequirementDiffTests and native exact review |
| Test/requirement linking | RequirementTraceabilityTests and native traceability publication |
| Stale test detection | Normal reruns resolve latest active; native stale status and deliberate historical inspection |
| Bug registry | ProjectBugStoreTests and native versioned bug editor |
| Manual Jira linking | Local reviewed ticket association, relinking and unlinking; external Jira verification is Phase 3 |
| Duplicate detection | BugComparisonTests, Runtime review tests, native known-ticket additions and ambiguity approval |
| CityPay bug skill | CityPayBugSkillTests, CityPayBugReportTests, native report preparation and duplicate gate |

## Current acceptance run

`TestResults/p2-11/mac-acceptance.xcresult` completed all 518 native Mac unit tests with zero failures on arm64 macOS 26.5.2 / Xcode 26.0. Its UI portion was intentionally interrupted for the user-requested filter-layout fix; it is not an all-green combined run. `ui-resumed.xcresult` now runs the traceability scenario and four duplicate-review/layout scenarios on the committed fix. It completed with four passes and one failure, detailed below. The subsequent primary iPhone 16 Pro / iOS 26.0 run passed 337 tests. Native runs were sequential.

The preceding P2-10d evidence is recorded in [its validation record](p2-10d-validation.md). That task passed 148 Runtime tests, 337 iPhone tests, native models/lifecycle, Keychain rechecks and three duplicate-review UI scenarios. This record does not silently convert those results into a new all-green Phase 2 run.

## Acceptance boundaries

The native latest/historical traceability scenario, stale-link semantics, known-ticket additional-evidence and reviewed publication flows have passing evidence. Existing native memory acceptance is recorded in [P2-10a](p2-10a-validation.md), registry editing/linking/history in [P2-10b](p2-10b-validation.md), and relationship/impact review in [P2-10c](p2-10c-validation.md). These records complement the full Mac and iPhone unit runs; they are not newly rerun UI tests.

The explicit traceability app-window attachment was visually inspected: historical inspection is checked, the view labels requirement v1, and its recorded link remains visibly potentially stale. The native UI test also checks current v2 before switching to historical v1 and verifies reviewed archival.

Physical display and broader device/runtime matrices remain final full-project acceptance, per user direction. Native integration uses synthetic data and a fake execution provider. Manual ticket association and local drafts do not verify an external Jira issue or publish one. Live Jira integration belongs to Phase 3. Temporary SQLite fixture teardown warnings and a separate intermittent offscreen picker interaction remain known validation limitations; neither is represented as fixed.

## Test-body review

`RequirementTraceabilityTests.testStaleLinksKeepProvenanceWhileNormalRerunsUseLatestActive` publishes active v1, draft v2 and active v3, then asserts normal resolution chooses v3 while explicit historical reproduction chooses v1 and preserves the original trace. `RequirementValidatorTests.testLatestActiveHistoricalAndRetirementUseExactStoredVersions` verifies drafts do not replace active behavior, deliberate historical evaluation is labeled, and retirement prevents ordinary evaluation. Their scope/environment test rejects foreign observations and reports absent rules as unavailable. These assertions support the Phase 2 resolver and stale-link requirements without claiming execution of company scenarios.

The full Mac log contains SQLite `vnode unlinked while in use` warnings during temporary BugEvidenceTests cleanup. Tests pass, but this remains a fixture lifecycle concern to assess, not a clean-log claim. It also reports deprecated custom identifier interpolation in the duplicate evidence UI. Neither warning is represented as fixed.

## Historical acceptance findings (superseded by completed results below)

The resumed UI run passed ambiguity transfer but the known-ticket scenario failed waiting for its prepared draft. The completed five-scenario result is recorded below.

The SQLite warning mechanism is confirmed in code: `RunCoordinatorTests.Fixture.remove()` shuts down execution then unlinks its root while the fixture/coordinator/service still retain store actors. `SQLiteConnection` closes its handle only on deinitialization. Shutdown releases execution ownership but does not release those retained store connections. This explains the temporary-fixture warning; it is not evidence of company data corruption and is not considered fixed.

## Platform and resumed UI results

`iphone.xcresult` passed all 337 tests on iPhone 16 Pro / iOS 26.0. `ui-resumed.xcresult` completed five native scenarios: four passed (ambiguity, report duplicate gate, compact selected-bug layout, latest/historical traceability) and one failed (known-ticket draft). The failed app hierarchy contains `bug.review.error`, proving draft preparation was attempted and rejected rather than a missing click. `ticket-diagnostic.xcresult` subsequently exercised the affected native model tests and known-ticket UI scenario with safe category-specific error messages. This failed run alone did not establish acceptance; the post-fix checks below complete the affected flow.

The interrupted diagnostic process handle was unavailable on resume, but its log records the known-ticket UI scenario passed (54.410 seconds), including v2 after relaunch. This does not establish the original failure's cause. `ticket-repeated.xcresult` subsequently ran three controlled UI iterations with safe diagnostic messages to check reproducibility.

## Repetition findings

`ticket-repeated.xcresult` completed three iterations: two passed and one failed during exact decision preparation after its ticket draft succeeded. The failure hierarchy contains a preparation error and the entered reason, distinguishing this from a missing click. The common catalog directory uses `LOCK_EX | LOCK_NB`; the background context observer retries its own reads, but registry reads may still encounter its lock. This is a hypothesis pending `ticket-contention.xcresult`, which reports `CatalogError.busy` safely and includes the visible error in failed test assertions. No automatic retries or weakened validation have been introduced.

`ticket-contention.xcresult` finished with one passing iteration and two failures: an offscreen decision-picker interaction, and a rejected decision publication shown in the app hierarchy. Neither exposes the original draft failure category. Publication diagnostics now distinguish a busy catalog too. Do not treat these failures as passing acceptance or evidence that contention is confirmed.

## Confirmed contention and validated correction

`publication-diagnostic.log` reproduced the original draft failure with the explicit message that project storage was busy. The native review session now cancels and awaits any in-flight background context observation before a foreground context check, then resumes periodic observation while skipping ticks during busy review actions. Foreground context and source validation remain mandatory; publication is not blindly retried. That diagnostic run ended with a failure; the subsequent correction was compiled, tested and committed as `5936867`. `monitor-coordination.xcresult` passed three model/lifecycle tests and the known-ticket UI scenario, including draft preparation, exact reviewed publication and v2 after relaunch. `monitor-lifecycle-final.xcresult` passed three tests, including twenty refreshes followed by context invalidation and busy recovery without a history mutation. See [the focused validation record](bug-review-contention-validation.md). No diagnostic process remains pending. The separate offscreen picker interaction from the earlier stress run is not claimed fixed.

## Reproduction commands and environment

Native Mac: arm64 macOS 26.5.2 (25F84), Xcode 26.0 (17A324). Native iPhone: iPhone 16 Pro, iOS 26.0 (23A343), simulator `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. All result bundles and logs are ignored local validation artifacts. Commands below are copied from the corresponding logs; choose a fresh result-bundle name when repeating them.

```sh
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination platform=macOS -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-11/mac-acceptance.xcresult "-only-testing:AgentDeskTests" "-only-testing:AgentDeskUITests/RequirementEditorUITests/testTraceabilityReviewCurrentHistoricalAndArchive" "-only-testing:AgentDeskUITests/BugDuplicateReviewUITests" -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination platform=macOS -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-11/ui-resumed.xcresult "-only-testing:AgentDeskUITests/RequirementEditorUITests/testTraceabilityReviewCurrentHistoricalAndArchive" "-only-testing:AgentDeskUITests/BugDuplicateReviewUITests" -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination platform=macOS -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-11/monitor-coordination.xcresult "-only-testing:AgentDeskTests/NativeBugReviewModelTests" "-only-testing:AgentDeskTests/NativeBugReviewSessionTests" "-only-testing:AgentDeskUITests/BugDuplicateReviewUITests/testKnownTicketDraftAndReviewedDecisionPersist" -parallel-testing-enabled NO test
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination platform=macOS -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-11/monitor-lifecycle-final.xcresult "-only-testing:AgentDeskTests/NativeBugReviewSessionTests" "-only-testing:AgentDeskTests/NativeBugReviewModelTests" -parallel-testing-enabled NO test
/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination "platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE" -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-11/iphone.xcresult "-only-testing:AgentDeskTests" -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```

Documentation integrity, section coverage, links and ignore-rule checks passed. No new product tests were invented for this documentation-only acceptance task.
