# P2-10a — Native memory, notes and inbox

Implemented and validated, 2026-09-11.

P2-10 is split into four focused commits without reducing scope: memory/notes/inbox, Bug Registry, traceability/impact, and duplicate/report review. After this task, four Phase 2 tasks remain including P2-11 acceptance. Phases 3–6 remain outstanding.

The memory store now supports bounded literal case/diacritic-insensitive search over current title/body/structured content/tags/logical path, alongside existing kind, environment, inactive-state and keyset filters. It searches authoritative stored records rather than treating a stale index as source truth. The native browser model loads filtered pages, resets paging/selection when filters change, loads immutable history, handles cancellation and rejects stores from another project.

Checks under ignored `TestResults/p2-10a/`:

- `search-tests.log`: initial failure on a structured endpoint whose JSON serialization escaped slashes.
- `search-fixed-tests.log`: nine memory-store tests passed after preserving normal slash spelling in search text.
- `model-tests.xcresult`: two native Mac model tests passed, zero failures/skips, macOS 26.5.2 (25F84), arm64.
- `editor-view-build.log` and `padding-memory-recheck.log`: build failures from missing `AgentDeskDesign` imports in the new memory views. Both imports were added.
- `padding-memory-fixed.xcresult`: 12 native Mac tests passed, zero failures/skips, including the Requirements modal regression in empty and populated/unselected states at compact and large sizes. The compact empty app-window screenshot was exported and visually inspected; the header retains its standard top inset. This rechecks the existing P2-03a fix.
- `core-tests.log`: all 192 Core tests passed, zero failures.
- `native-memory-ui.xcresult`: 14 passed, zero failures/skips: five memory-model tests, six native layout tests, two command tests and the note publication/promotion/history/relaunch UI scenario. Initial app-window review screenshot was inspected, prompting a readable changed-field presentation in place of full JSON blocks.
- `inbox-ui.xcresult`: cancelled-review, command routing, ignored-inbox filtering and search UI scenario passed, zero failures/skips.

The native browser and editor are now wired through the project Memory action and scoped command search. Review binds the exact sanitized candidate; later draft-binding mutations do not change publication. Native model checks cover cancelled review, promotion, archive, stale proposals, foreign sources and immutable history. Native Mac and iPhone checks passed. The final physical-display and multi-device/runtime acceptance matrix remains deferred as requested.

- `readable-review.xcresult`: 14 passed, zero failures/skips after replacing raw JSON review with changed fields. The final app-window screenshot was visually inspected: content/kind/topic changes are readable and Cancel/Publish remain reachable.
- `review-fields.xcresult`: all six native model tests passed after adding exact typed change comparison and an ambiguous-tag-boundary regression.
- `iphone-final.xcresult`: all 333 tests passed, zero failures/skips, on iPhone 16 Pro / iOS 26.0 (23A343), simulator `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. This is an actual Simulator test run.
- Documentation integrity, coverage, local links, ignore rules and whitespace checks passed.

## Commands

All native Mac runs use macOS 26.5.2 (25F84), arm64, Xcode 26.0 (17A324). Outputs stay under ignored `TestResults/p2-10a/`.

```sh
swift test --package-path Packages/AgentDeskCore --filter ProjectMemoryStoreTests
swift test --package-path Packages/AgentDeskCore
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10a/padding-memory-fixed.xcresult -only-testing:AgentDeskTests/NativeMemoryModelTests -only-testing:AgentDeskTests/NativeCommandCatalogTests -only-testing:AgentDeskTests/MacEditorLayoutTests -only-testing:AgentDeskUITests/RequirementEditorUITests/testRequirementBrowserHeaderStaysAtTopInEmptyAndUnselectedStates -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10a/native-memory-ui.xcresult -only-testing:AgentDeskTests/NativeMemoryModelTests -only-testing:AgentDeskTests/NativeCommandCatalogTests -only-testing:AgentDeskTests/MacEditorLayoutTests -only-testing:AgentDeskUITests/MemoryEditorUITests -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10a/inbox-ui.xcresult -only-testing:AgentDeskUITests/MemoryEditorUITests/testCancelledReviewAndIgnoredInboxFilters -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10a/readable-review.xcresult -only-testing:AgentDeskTests/NativeMemoryModelTests -only-testing:AgentDeskTests/NativeCommandCatalogTests -only-testing:AgentDeskTests/MacEditorLayoutTests -only-testing:AgentDeskUITests/MemoryEditorUITests/testReviewedNotePromotionAndHistorySurviveRelaunch -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10a/review-fields.xcresult -only-testing:AgentDeskTests/NativeMemoryModelTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-10a/iphone-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```
