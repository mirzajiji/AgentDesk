# P1-14c — First-run readiness and native layout audit

Date: 2026-09-10. Baseline `0d5a5ed`. Implementation and affected validation are complete for this task; full Phase 1 and physical-display acceptance remain pending.

The first layout pass replaces fixed outer sizes in the older agent, skill, shared-instruction and Codex Settings editors with the shared native resizable layout. Project rows use horizontal content when it fits and place actions beneath the project title in compact windows, preserving full button labels.

Checks under ignored `TestResults/p1-14c/`:

- `layout-build.log`: native build succeeded but the initial test selector named a nonexistent class, so **zero tests ran**. This is build evidence only.
- `layout-tests.log`: the corrected `MacEditorLayoutTests` selector ran three passing tests, including actual agent/skill editor sizing across compact and large logical proposals, scale values 1/2 and normal/enlarged Dynamic Type. These tests do not prove internal clipping or physical display behavior.
- `compact-ui.log`: native compact-window test passed at approximately 910×720 logical points. All project actions are reachable with untruncated widths, actions move below the title, and the agent editor’s name/save controls remain reachable. The app-window screenshot was exported and visually inspected; all four action labels are fully visible.

The readiness screen now checks readable catalog/project configuration, invokes only `/usr/bin/git --version` with fixed arguments, bounded output and a five-second timeout, and uses the existing signed Codex helper to inspect installation/authentication. Readiness does not grant run permission, create defaults or start a provider. Recovery actions route to Settings and existing scoped creation/setup screens after dismissing the sheet. Closing cancels checks and invalidates late results.

- `readiness-build.log`: an initial compile failed due to a missing explicit Core import in the new view; corrected before tests.
- `readiness-tests.log`: four native tests pass for observed-item publication, cancellation/late results, sanitized failure messages and strict numeric Git version extraction. These tests use fake probes and captured output; they do not require a live Codex account.

- `readiness-ui.log`: both native readiness tests passed: Escape/close, unsaved workspace-form routing and Codex Settings controls.
- `mac-final.log`: all 346 Mac unit/integration tests passed. Five of six UI scenarios passed, including skill editing, shared instructions, readiness and compact rows. Xcode’s result summary records the agent-editor test as “Test crashed with signal kill” during launch; the combined command failed. It is not counted as a green full-suite run.
- `iphone-final.log`: 228 actual iPhone 16 Pro tests passed on iOS 26.0.
- Git parsing was tightened to reject empty numeric components such as `2..1`; `agent-parser-final.log` passes all four readiness/parser tests and the previously killed agent-editor scenario (43.492 seconds). The original kill remains recorded; no cause is inferred from the successful rerun.

- `release-mac.log`: production Release build passed. Strict deep code-signature verification passed for the app/helper bundle.
- Documentation integrity/link checks and diff checks passed before staging.

All affected scenarios have passing evidence on their final source. The combined native command that recorded a killed test remains a failed run. Broader final acceptance and the requested physical monitor/scaling matrix remain pending. The physical 32-inch 4K, 27-inch 2K, 16-inch 4K and 14-inch 4K display matrix remains final-product acceptance work.

## Reproduction

Use the shared `AgentDesk` scheme in `AgentDesk.xcodeproj`, native destination `platform=macOS`, derived data `TestResults/p1-01/NativeMac`, `-parallel-testing-enabled NO` and a unique result-bundle path. The full native command selected `AgentDeskTests`, `NativeReadinessUITests`, `NativeWindowLayoutUITests` and the three `AgentDeskUITests` methods for agent persistence, skill creation/pinning, and shared-instruction preview, with a 180-second per-test timeout. The focused final rerun selects `AgentDeskTests/NativeReadinessTests` and `AgentDeskUITests/AgentDeskUITests/testAgentInstructionsPersistAcrossEditArchiveRestoreAndRelaunch`.

The iPhone run uses destination `platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`, derived data `TestResults/p1-08b/FilteredIPhone`, and `-only-testing:AgentDeskTests test`. Environment: macOS 26.5.2 / Xcode 26.0. Existing SQLite fixture-teardown warnings remain. Documentation checks use `python3 Scripts/validate-documentation.py` and `git diff --check`.
