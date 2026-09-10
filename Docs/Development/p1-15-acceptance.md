# Phase 1 acceptance audit

Baseline: `ce38913`, 2026-09-10. **Phase 1 acceptance passes.** The complete six-phase goal remains active. This record does not declare any of the later phases complete.

## Architecture section 110 requirements

The original Phase 1 list is the acceptance scope. The 23 bullets are grouped below where one subsystem supplies related requirements. Baseline native suites, the real fresh-app critical slice and final affected regressions establish Phase 1; they do not establish the later capability phases.

| Requirement | Existing implementation/evidence to verify at acceptance |
| --- | --- |
| SwiftUI macOS app and navigation | Native app and split-view shell, command routing, Runs page; P1-01/P1-14a/b/c records |
| Workspace and project creation | WorkspaceCatalog, WorkspaceBrowserModel, native create/rename/reopen/isolation UI tests |
| Filesystem architecture | ConfigurationDirectory, scoped paths and traversal/symlink/hard-link tests; P1-02/03 records |
| Local SQLite | OperationalStore, migrations, run/step/event/approval/evidence persistence; P1-04/07/10/12 records |
| Keychain abstraction | Scoped SecretStore and actual native Keychain integration tests; P1-05 record |
| Agent CRUD | Versioned project agent creation/edit/archive/restore and native UI persistence; P1-06a |
| Instructions editing | Agent/shared instruction versions, composed source preview; P1-06b1 |
| Configuration composition | Effective execution/environment settings, provenance and output schemas; P1-06b2/P1-13b |
| Codex detection and login/status | Supported diagnostics through signed helper and native Settings; P1-08a/b |
| Codex CLI provider | Bounded process transport, read-only provider and signed execution bridge; P1-09a/b/P1-11b |
| Run and RunStep models | Persisted lifecycle, typed stages and deterministic progress; P1-07a/b |
| Live Codex output | NativeRunSession sequence subscriptions/replay plus incremental redacted evidence preview; this acceptance record |
| Traces and artifacts | Redacted scoped EvidenceStore and native saved-result inspection; P1-12a/b/P1-13c2 |
| Changed-file tracking | Deterministic Git snapshots and diff capture; P1-12c; native synthetic diff presentation is separate evidence |
| Approvals foundation | PolicyGate, immutable exact-action binding, review/consume/audit and native approve/reject; P1-10/11/13c2 |
| Command palette | Command-K, scoped search and existing capability routes; P1-14a |
| Basic menu bar | Persisted open-session counts and cross-window console focus; P1-14b |
| Tests | Native Mac unit/integration/UI, iPhone 16 Pro tests, package and documentation records; fresh combined run below |

## Verified native critical slice

Fresh native workspace → project → agent → edited instructions → configured repository/environment → explicit review/approval → real Codex execution → live steps → result/files inspection.

Earlier component checks were insufficient by themselves. This acceptance run used a new synthetic repository and the existing authorized Codex account, preserving existing user workspaces, login state and unrelated worktree changes. It required no new credentials or company data.

`NativeCriticalSliceUITests` now defines an explicit opt-in scenario using a UUID-isolated app catalog, a temporary Git repository, native create/edit/setup controls and the real signed helper. It checks explicit approval, an observed running state, completion, exact file-derived output, baseline/current repository observations, unchanged source and reopening saved evidence. The first real run passed in 111.060 seconds: `live-critical-slice.log`/`.xcresult`, one test passed, zero failures and zero skips. The app-window attachment was inspected and shows completed native stages, observed repository snapshots and the exact synthetic file-derived result. This run predates the live-text display fix; that change has separate regression coverage below.

Run it explicitly with an existing signed-in Codex installation:

```sh
TEST_RUNNER_AGENTDESK_LIVE_ACCEPTANCE=1 xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-15/live-critical-slice.xcresult \
  -only-testing:AgentDeskUITests/NativeCriticalSliceUITests \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 300 test
```

The test intentionally skips without `AGENTDESK_LIVE_ACCEPTANCE=1` in the test runner. It never sets the app's fake-provider mode, changes login state or uses company data. Native UI tests must run serially, including across separate Xcode commands.

## Acceptance findings

- The baseline console showed persisted state/work-plan events but automatically loaded provider text only after completion. The acceptance fix adds `NativeLiveOutputModel` and an incremental native preview of already-redacted provider evidence. Five initial unit regressions pass for pre-completion output, redaction, bounded paging, identity isolation, cancellation/late reads and unavailable content. A synthetic provider that emits a message and then waits for cancellation exercises actual native pre-completion display. The final affected native run passed: 351 unit/integration tests and eight native UI scenarios. Its live-output screenshot was inspected: the run and Agent stage are running, collection is pending, text is visible with the synthetic password redacted, and Cancel remains reachable. A final two-line stale-generation guard was then verified by rerunning all five model tests.
- The Agents panel footer now directs users to review instructions and use the project Run console, replacing the stale claim that execution was coming next.

## Fresh checks

`TestResults/p1-15/native-acceptance.log` and `.xcresult`: full native Mac scheme test run against the baseline passed, exit 0. `xcresulttool get test-results summary` reports **375 tests passed, 0 failed, 0 skipped**, with 376 device executions because one test has two dynamic parameter runs. The unit/integration bundle reports 346 tests; the remaining tests are native UI/launch coverage. Environment: macOS 26.5.2 (25F84), arm64, Xcode 26.0. Parallel testing was disabled and the per-test timeout was 180 seconds. This baseline run predates the opt-in critical-slice test and does not establish live-provider acceptance.

The legacy `Scripts/check-foundation-sources.py` and tests for its removed manual runner are retired. It assembled only Core/Design and could not compile the current app graph. README now directs developers to the real shared Xcode scheme. Historical records and Git history preserve the original checker and its results; no historical result was overwritten, and no replacement source-only check is presented as a native build or Simulator run.

## Final affected validation

All artifacts below are ignored under `TestResults/p1-15/`. Native environment: Xcode 26.0 (17A324), macOS 26.5.2 (25F84), arm64.

| Record | Result and scope |
| --- | --- |
| `native-acceptance.log` / `.xcresult` | Full baseline scheme: 375 passed, zero failures/skips; 376 executions including a parameterized repeat |
| `live-critical-slice.log` / `.xcresult` | Real signed Codex helper, fresh native setup, approval, live steps, exact result, repository snapshots and reopening: 1 passed, zero skips |
| `live-output-unit.log` / `.xcresult` | Five new model regressions passed |
| `live-output-native.log` / `.xcresult` | 351 Mac unit/integration tests and eight affected console/agent UI tests passed, zero failures/skips |
| `final-guard-tests.log` / `.xcresult` | Final model code: five passed. Live-account test intentionally skipped once because opt-in was absent; this is not live acceptance evidence |
| `iphone-final.log` / `.xcresult` | Actual iPhone 16 Pro Simulator, iOS 26.0 (23A343), device `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`: 228 passed, zero failures/skips |
| `release-mac.log` | Release app build passed; app deep/strict and embedded helper strict signature checks passed |

Commands (each test run used its own result bundle listed above):

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-15/native-acceptance.xcresult -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-15/live-output-unit.xcresult -only-testing:AgentDeskTests/NativeLiveOutputModelTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-15/live-output-native.xcresult -only-testing:AgentDeskTests -only-testing:AgentDeskUITests/ProjectRunConsoleUITests -only-testing:AgentDeskUITests/AgentDeskUITests/testAgentInstructionsPersistAcrossEditArchiveRestoreAndRelaunch -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 180 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-15/final-guard-tests.xcresult -only-testing:AgentDeskTests/NativeLiveOutputModelTests -only-testing:AgentDeskUITests/NativeCriticalSliceUITests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p1-15/iphone-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -configuration Release -destination 'platform=macOS' -derivedDataPath TestResults/p1-13c2/ReleaseMac build
codesign --verify --deep --strict TestResults/p1-13c2/ReleaseMac/Build/Products/Release/AgentDesk.app
codesign --verify --strict TestResults/p1-13c2/ReleaseMac/Build/Products/Release/AgentDesk.app/Contents/XPCServices/AgentDeskCodexHost.xpc
python3 Scripts/validate-documentation.py
git diff --check
```

Documentation checks pass source integrity, all 159 numbered sections, 21 required architecture pages, coverage and local links. The removed manual checker had no callers besides its removed dedicated tests and the replaced README invocation. Historical prose references are retained as historical evidence.

## Explicit remaining limits

- Physical 32-inch 4K, 27-inch 2K, 16-inch 4K and 14-inch 4K monitor/scaling coverage remains final-product acceptance work; logical window tests do not prove hardware coverage.
- The broader compact/large/minimum/newest iPhone matrix is deferred to final-product acceptance per the user's instruction; routine validation uses iPhone 16 Pro/iOS 26.0.
- Later command capabilities, historical menu totals, pause behavior, secure pairing and phases 2–6 remain pending. Basic Phase 1 controls do not imply the complete corresponding architecture sections are implemented.
- Existing SQLite fixture teardown warnings and prior killed/intermittent test runs remain recorded. They must not be erased by later passing retries.
