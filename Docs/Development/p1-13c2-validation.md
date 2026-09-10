# P1-13c2 — Native context inspector and run console

Date: 2026-09-10. Starting commit: `216938d`, branch `codex/native-foundation`. Implementation and final-source acceptance are complete. This validates the Phase 1 console task, not the complete 159-section product.

## Implemented behavior

- Project Run opens agent/environment selection, current instructions/source versions/effective configuration review and native plain task entry. No provider starts merely by opening or reviewing context.
- Preparation revalidates current sources and freezes sanitized input. The displayed input artifact is checked against its immutable fingerprint. Exact prepared actions require explicit approve/start or reject; edited sources require another review.
- Authorized live subscriptions use durable sequences, bounded buffers, replay recovery and exact project/environment/agent evidence binding. Read policy is rechecked during forwarding; observation cancellation does not cancel execution.
- Sessions own execution/observation lifetimes. Cancellation and close await shutdown and release project ownership. In-app configuration writes stop affected sessions before replacing settings; external source changes are checked every 500 ms. Cancelled monitoring does not report a false source change. Deinitialization also releases registry ownership.
- Persisted state and steps drive the UI. Open-ended runs never invent an overall percentage. Confirmed final results select the stored artifact with its provenance; missing results remain unavailable. Late reads cannot reopen a cleared browser or replace newer selections.
- Saved-run browsing requires no Codex login, repository grant, execution lease, recovery or new task. Current policy is checked before and after archive reads. Scope/agent/environment filtering precedes pagination; foreign cursors and bindings fail closed. Empty archives create no database.
- Evidence and diffs display selectable plain text with source and observed/interpretation basis. The native editor disables prose substitutions and now honors SwiftUI's disabled state in NSTextView itself.
- The console scrolls its content and keeps Done fixed. Its preferred height is 640 logical points. UI acceptance includes 910×720 and 1400×900 parent windows.

The normal application uses the signed Codex helper and real repository registration. UI tests use only a Debug fixture requiring a valid UUID test-container identity and an allowlisted mode. Its seed/factory check the derived private test root/database; it never selects user repositories or starts Codex. Release excludes the fixture. Synthetic diff injection tests presentation; existing Git capture integration tests verify actual repository capture.

## Final-source checks

All output lives under ignored `TestResults/p1-13c2/`.

| Check | Result / evidence |
| --- | --- |
| Native Mac unit/integration suite | 333 passed in `acceptance-mac.log`, including both actual Keychain tests |
| Console native UI | Six passed in `acceptance-mac.log`: approve/result/relaunch, active close/reopen, compact cancellation, empty context/keyboard close, rejection, large-window diff |
| Setup native UI | All four passed in `acceptance-mac.log` (154.771 seconds); total native UI: ten passed |
| iPhone Simulator | 226 passed in `acceptance-iphone.log` / `.xcresult` |
| Normal signed Mac build | Passed in `acceptance-normal.log` |
| Release Mac build | Passed in `acceptance-release.log` |
| Final normal/Release signatures | `codesign --verify --strict --deep` passed for both app bundles and embedded helpers with native trust access |
| Release fixture exclusion | Executable contains none of `AGENTDESK_TEST_RUN_MODE`, `NativeRunUITestSupport` or the synthetic result marker |
| Documentation | Passed: source SHA-256, all 159 sections, ownership/coverage, links and ignore rules; git diff check passed |

Environment: macOS 26.5.2 (25F84), arm64; Xcode 26.0 (17A324), Swift 6.2. Primary local Simulator: AgentDesk iPhone 16 Pro, `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`, iOS 26.0 (23A343). The iPhone result is an actual test run, not build-only coverage. Ordinary tests use fake providers and isolated synthetic storage. No live Codex request was needed for this task's UI acceptance.

## Reproduction

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-13c2/acceptance-mac.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -only-testing:AgentDeskUITests/ProjectRunConsoleUITests -only-testing:AgentDeskUITests/ProjectSetupUITests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p1-13c2/acceptance-iphone.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -configuration Release -destination 'platform=macOS' -derivedDataPath TestResults/p1-13c2/ReleaseMac build
codesign --verify --strict --deep TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app
codesign --verify --strict --deep TestResults/p1-13c2/ReleaseMac/Build/Products/Release/AgentDesk.app
python3 Scripts/validate-documentation.py
git diff --check
```

Use fresh result-bundle paths for reruns. Earlier focused package commands were `swift test --package-path Packages/AgentDeskRuntime --filter NativeRunServiceTests`, the same with `NativeRunArchiveTests`, and Persistence's `BoundRunHistoryTests` filter. Native focused runs use the same Mac command with their test-class selectors.

## Findings fixed during validation

| Evidence | Finding and correction |
| --- | --- |
| `native-observation.log` | Async call in XCTUnwrap corrected; seven stream/service tests passed in `native-observation-complete.log` |
| `bound-history.log`, `context-model.log` | Two scoped pagination tests and twelve native context/history/service tests passed |
| `registry-tests.log`, `session-tests.log` | Three registry tests passed; missing Synchronization import in new session tests corrected |
| `session-tests-corrected.log`, `session-snapshot.log` | Input review initially returned the action binding rather than input content; now reads and verifies the actual command artifact. Six tests passed in `session-input-fixed.log` |
| `console-build.log`, `evidence-model*.log` | Missing explicit module imports corrected; five model tests and initial UI passed in `console-first-native.log` |
| `archive-tests.log`, `archive-native.log` | Archive noninterference, policy revocation, no-database empty browsing and isolation passed; eight native tests plus initial UI passed |
| `automatic-results.log`, `session-completion-revocation.log`, `stale-result.log` | Automatic result selection, confirmed completion, external-source shutdown and deterministic late-read rejection passed |
| `full-console-ui*.log` | Scroll targeting/direction corrected; prepared fingerprint now uses its raw value. Full approval/result/relaunch passed in `full-console-ui-direction.log` |
| `console-cancel-ui.log`, `console-close-ui.log` | Window and Touch Bar confirmation duplicates distinguished. Compact screenshot exposed excessive sheet height; corrected. Both cases passed in `console-close-compact.log` |
| `final-mac.log` | 332 unit/integration and four setup UI tests passed, but two console UI cases failed. Viewport-bounded clicking and cancellation-aware source monitoring corrected both; five session and two UI tests passed in `result-race-ui.log` |
| `editor-disabled.log` | Two native editor tests passed after propagating disabled state to AppKit |

Restricted signature verification once returned `CSSMERR_TP_NOT_TRUSTED`; the same verification passed with native trust access. Existing SQLite fixture-teardown diagnostics remain in native logs and are not claimed as resolved here.

## Visual evidence and limits

App-window screenshots were inspected from `console-first-attachments/`, `full-console-accepted-attachments/`, `compact-console-accepted/`, and `large-diff-attachments/`. The final diff test additionally checks that the whole short diff fits inside the visible scroll viewport before capturing. Only synthetic app-window attachments were used; unrelated full-screen recordings were not inspected or tracked.

Physical 32-inch 4K, 27-inch 2K, 16-inch 4K and 14-inch 4K display/scaling checks remain in the final product matrix. The broader iPhone device/runtime matrix is deferred as requested. P1-14 navigation/interaction polish and P1-15 Phase 1 acceptance remain, along with phases 2–6. The legacy `check-foundation-sources.py` manual-compiler gap remains a later validation-tooling task; native Xcode builds are the evidence here.

## Commit scope

Keep unrelated Xcode project normalization, personal scheme metadata and `continue-in-updated-project.md` wording out of this commit. The focused task commit contains console/runtime/persistence/design changes, their tests and documentation. Personal author/committer and the exact authorized GitHub fetch/push remote were verified. Git history records the commit; push is verified separately after committing.
