# P1-14b — Menu bar status and run navigation

Date: 2026-09-10. Baseline `2c08cba`. Implementation and affected acceptance are complete. This is the Phase 1 basic menu/run-navigation task, not full section 81 or product completion.

The native registry now publishes persisted state from its registered session owner. Older sequences, released owners and foreign ownership cannot replace a current summary. Release/configuration shutdown removes status and focus callbacks. MenuBarExtra shows running, awaiting-approval and failed counts explicitly scoped to open sessions, with actions to focus their existing native consoles. It does not infer historical totals from the open-session registry.

The Runs page lists open sessions and project consoles/history instead of claiming there are no runs. Project navigation uses the existing scoped command route and focuses an existing console before attempting to open another. A weak native-window callback avoids retaining the session through presentation ownership. Pause controls remain unavailable until runtime pause is implemented; this task does not substitute cancellation for pause.

Initial checks under ignored `TestResults/p1-14b/`:

- `registry-build.log`: existing native registry/session tests passed with observable status storage.
- `native-menu-build.log`: build failed due to missing explicit Core imports in the new menu/view; imports were added.
- `native-menu-build2.log`: native Mac build and 11 registry/session tests passed, including real persisted approval/running transitions, stale sequence rejection, release cleanup and 25 reviewed starts.

Additional checks:

- `runs-ui2.log`: all five registry tests passed, including failed-state counts, foreign owner rejection and configuration-stop cleanup. UI launch restoration still failed in this run.
- UI launches restored a no-window state after adding MenuBarExtra. The main scene now explicitly requests presented launch behavior; synthetic UI fixtures use `-ApplePersistenceIgnoreState YES` to avoid inheriting window restoration across tests. The menu image has an explicit AgentDesk accessibility label.
- `runs-ui4.log`: both empty menu counts and Runs → scoped console → selected-agent empty history tests passed. Native status items require XCTest’s `statusItem` query, not `menuBarItems`.
- `active-menu-ui2.log`: approval count 1, existing-console menu action, single sheet, running count 1, approval count 0, confirmed stop/close and empty-session cleanup passed. The first active test used a custom identifier that SwiftUI did not preserve on NSMenuItem; the corrected query uses its displayed title.

- `cross-window.log`: a second main window’s Runs page focuses the original prepared console; the menu also focuses it, and the sheet/run remains singular through approval, start and close.
- `iphone-final.log`: all 228 actual iPhone 16 Pro tests passed on iOS 26.0.

- `mac-final.log`: all 341 native unit/integration tests and seven of eight selected UI tests passed. The cross-window scenario failed with an XCTest menu-open notification timeout; this full command is recorded as failed.
- The menu test now waits for a hittable, nonzero-size menu item and clicks its center, avoiding XCTest’s implicit menu-opening action. `menu-final.log` passes all three menu/history scenarios twice on the final test source (six UI runs).

- `release-mac.log`: production Release build passed; `codesign --verify --deep --strict` passed for the resulting app/helper bundle.
- Documentation integrity/link checks and diff checks passed before staging. The earlier full UI command remains a recorded failure; all affected scenarios passed on their final test source.

Pause and historical aggregate counts remain outside this basic task. The final product audit must still verify the broader section 81 capabilities. macOS 26.5.2 / Xcode 26.0; the primary iPhone Simulator remains iPhone 16 Pro / iOS 26.0. Physical display and broader iPhone matrix acceptance remain pending.

## Final check commands

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-14b/mac-final.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -only-testing:AgentDeskUITests/NativeRunsUITests -only-testing:AgentDeskUITests/NativeCommandPaletteUITests -only-testing:AgentDeskUITests/AgentDeskUITests/testSidebarNavigatesBetweenEmptySections -only-testing:AgentDeskUITests/ProjectRunConsoleUITests/testApproveCompletesAndSavedResultReopensAfterLaunch -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p1-14b/iphone-final.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests test
python3 Scripts/validate-documentation.py
git diff --check
```

Use unique result-bundle paths for repeated checks. Existing SQLite fixture-teardown warnings remain; these checks do not establish the final physical display matrix.
