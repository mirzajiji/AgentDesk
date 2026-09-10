# P1-14a — Native command palette and scoped routing

Date: 2026-09-10. Starting commit: `37159e0`, branch `codex/native-foundation`.

## Behavior

Command-K and File → Command Palette open a searchable native sheet in the focused main window. Search folds case and accents and matches all query words against the command title and workspace/project context. Stable typed identities distinguish identically named projects in different workspaces. Results are bounded; missing matches disable Open. Return opens the selected result, Escape cancels, and dispatch is accepted only once per presentation.

Implemented routes are Settings, Create Workspace, Switch Workspace, Create Project, Manage Agents and Skills, Project Setup and Run Agent. The palette dismisses before the destination opens. Project routes resolve the live catalog again, including after asynchronous workspace selection; missing or foreign scopes fail closed. Opening Run Agent opens the existing review console and never prepares, approves or starts execution. Creating a workspace or project opens the existing form without saving automatically. Catalog discovery creates no execution storage.

Section 80's workflow, knowledge, bug, integration and approval commands remain owned by their respective capability phases. This task does not claim those unavailable capabilities, menu bar status, first-run readiness, or full-product completion. P1-14 is now three focused tasks (a/b/c), followed by P1-15 acceptance.

## Checks

Environment: native arm64 Mac, macOS 26.5.2, Xcode 26.0; primary local Simulator is AgentDesk iPhone 16 Pro, iOS 26.0, UUID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. Logs and result bundles are ignored under `TestResults/p1-14a/`.

- `command-catalog.log` and `palette-build2.log`: two native Mac catalog tests passed; search accents, same-name scope identity, bounded/empty results, renamed/missing/foreign projects and no execution-storage side effects.
- `palette-ui2.log`: two native UI tests passed. Command-K/Return opens the review console without starting a run, subsequent project creation retains workspace context, empty search disables Open, Escape closes, and controls fit a 910×720 parent window.
- Exported and visually inspected the app-window attachment `Compact native command palette`: search, empty state, Cancel and Open remain visible. This is a logical window check, not physical monitor acceptance.
- `mac-acceptance.log`: all 335 Mac unit/integration tests passed, including both actual Keychain tests; both palette UI tests and five of six console UI tests passed. The entire command exited 65 because the large-window diff case failed waiting for output.
- `routing-final.log`: both catalog tests passed after adding current workspace refresh and missing-workspace rejection. The large-window diff test passed on this rerun. Two palette UI tests passed; the new arrow-key test exposed a search-field event handling defect.
- `keyboard-fix.log`: all three palette UI tests passed after adding explicit up/down key handling to the search field. This builds the final Mac source. Return, Escape, arrow selection, scoped console/form routing and compact empty state are covered.
- `iphone.log`: 226 actual iPhone 16 Pro Simulator tests passed; the native iOS target builds with Mac-only commands excluded.
- Documentation integrity/link checks and `git diff --check` passed before staging.

The broader console failure's exported app accessibility hierarchy showed `waitingForApproval` and a generic run-operation error. The unchanged console test passed on focused rerun; the original failure is not treated as a green full-suite run or a proven fix. Its intermittent approval/start cause remains an explicit P1-15 acceptance investigation. Existing SQLite teardown warnings also remain. The command-palette-specific final checks pass.

The initial build failed because a conditional Scene modifier and Settings declaration shared one conditional block; separating the conditional blocks corrected the Swift parser error. The first routing UI query matched the fixture workspace's word “run” as well as the Run Agent title; the test now requests “run agent synthetic” explicitly. The compact UI test passed on both runs.

## Reproduction

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-14a/mac-acceptance.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -only-testing:AgentDeskUITests/NativeCommandPaletteUITests -only-testing:AgentDeskUITests/ProjectRunConsoleUITests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p1-14a/iphone.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests test
python3 Scripts/validate-documentation.py
git diff --check
```

Use a new result-bundle path for repeated Xcode runs. The broader iPhone device/runtime matrix and physical Mac monitor/scaling matrix remain final-product acceptance work. Existing compact workspace-row truncation is part of the P1-14c layout audit; the palette itself is readable and its actions are reachable.
