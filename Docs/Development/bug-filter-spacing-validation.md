# Bug Registry filter spacing regression

The user screenshot shows four vertically stacked filters above the selected bug. The existing title inset is not the gap in that screenshot. Replace the adaptive lazy grid with two explicit, intrinsically sized native grid rows: status/environment and ticket/archive. This brings the list and selected detail upward while preserving the scrollable split view and all filtering behavior.

The native UI regression checks paired control alignment, filter height, selected detail distance from the last filter, and selected detail distance from the sheet top in a compact window. It also exercises ticket validation, publication, editing, historical selection, relaunch and archive filtering. Existing native layout and bug-model unit tests cover sizing and data behavior. No business logic changed.

## Validation

Environment: macOS 26.5.2, Xcode 26.0. macOS-only view change; no iPhone code changes or new Simulator coverage claimed. Physical multi-display acceptance remains deferred.

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/bug-filter-spacing.xcresult -only-testing:AgentDeskTests/MacEditorLayoutTests -only-testing:AgentDeskTests/NativeBugModelTests -only-testing:AgentDeskUITests/BugEditorUITests/testTicketReviewUnlinkHistoryAndArchiveSurviveRelaunch -parallel-testing-enabled NO test
```

Passed: 14 native unit tests (8 layout, 6 bug model) and 1 native UI regression, zero failures. The exported selected-bug screenshot was visually inspected: filters occupy two rows and the list/detail begin directly below them. Normal signed macOS build also passed (`xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build`, log `TestResults/bug-filter-spacing-build.log`). Documentation validator and `git diff --check` pass. Artifacts are ignored under TestResults. This regression does not complete an additional architecture task: 52 documented tasks complete, 11 Phase 3 tasks remaining plus Phases 4–6.
