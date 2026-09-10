# P1-13c1 native project setup screens — accepted

Date: 2026-09-10. Starting commit `8cb995d`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, macOS 26.5.2 (25F84), arm64. Primary Simulator: AgentDesk iPhone 16 Pro, iOS 26.0 (23A343), `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.

**Native acceptance passes: 310 Mac unit/integration tests, four Mac UI tests and 224 iPhone tests.** The Mac unlock removed the earlier UI/Keychain blocker. The normal signed Mac build and strict app/helper signature checks pass. P1-13c1 covers setup screens; the context/run console remains P1-13c2. This task does not complete Phase 1 or the six-phase product.

## Implemented behavior

Each project row has **Setup**. The native sheet shows repository registration, verified read-only access, workspace settings and project settings. `NSOpenPanel` selects one directory and the existing scoped registry validates Git/root/bookmark identity. Reload checks actual access. Removing a registration preserves the repository folder and files.

Starting execution settings are editable proposals. Cancel does not save; Save publishes a new version using an expected revision. Forms edit model, activity/time/output ceilings, evidence/run permissions, workspace lock and project environments. Disabling/removing the default environment clears its selection. Advanced saved constraints and unrelated policy rules survive basic edits. Missing environment policy remains denied.

Advanced JSON exposes the complete document, including allowlists, output schema and policy rules. Bounded duplicate-key-rejecting decoding and exact scope validation happen before applying to the form. Apply does not persist; Save Settings is still required. Error messages describe validation categories without exposing raw errors or credentials.

The JSON field uses a native `NSTextView` through `MacPlainTextEditor`. It disables quote/dash/text/spelling substitutions and rich text, retains scrolling, undo and accessibility identifiers, and updates the SwiftUI binding through its delegate. This fixes the observed smart-quote corruption described below. No global typing preference is changed.

The factory checks project membership before creating private storage. Descriptor-relative 0700 directories separate machine-local `RepositoryAccess` from portable `Workspaces`; SQLite is under `Data/<workspace UUID>/operations.sqlite`. Linked/replaced or unsafe private directories fail closed. UI tests use isolated UUID containers and synthetic data. No live Codex call was required for these screens.

## Accepted evidence

| Check | Result and output under ignored `TestResults/p1-13c1/` |
| --- | --- |
| Full native Mac units/integration | **310 pass**, including both real Keychain tests; `mac-accepted.log` / `.xcresult` |
| Native Mac setup UI | **Four pass**, zero failures; same accepted bundle |
| Native iPhone 16 Pro, iOS 26.0 | **224 pass**; `iphone-plain-editor.log` / `.xcresult` |
| Normal signed Mac build | Pass; `normal-mac-plain-editor.log` |
| Strict app/helper signatures | Pass; no entitlement changes introduced |
| Documentation and diff checks | Source integrity, all 159 sections, links/ignore rules and `git diff --check` pass |

The four accepted UI scenarios verify:

1. Starting-setting cancellation, invalid timeout feedback, explicit workspace/project saves and persistence across app relaunch.
2. Invalid JSON rejection, exact typed text, advanced model allowlist/output-schema application, explicit save and reopening after relaunch.
3. External synthetic Git directory selection through `NSOpenPanel`, verified bookmark access before/after app relaunch, displayed path and registration removal preserving `.git/HEAD`. The directory belongs to the test runner container, outside the app container.
4. Resizing the native app to approximately 910×720 logical points, reachable setup/save/apply controls, visible JSON error feedback and Escape cancellation without persistence.

App-window screenshots were inspected in `accepted-attachments/` and `compact-attachments/`: long repository paths wrap; JSON scrolls; action rows and validation messages remain visible. Offscreen tests additionally measure execution/JSON editor roots at seven logical sizes from 600×480 to 3840×2160, scale values 1/2 and normal/enlarged text settings. Those measurements establish root sizing only, not all internal rendering or physical hardware coverage.

Five setup-model tests cover no-write proposals, explicit saves, conflicts, native bookmarks, active-access protection, cancellation, foreign scopes and private-storage symlinks. Five draft-edit tests cover complete JSON/schema/policy round-trips, invalid/duplicate/unknown/oversized/foreign inputs, environment removal, exact policy preservation and the UI's JSONSerialization edit. Two layout tests and one native plain-text regression cover sizing and exact structured-text preservation/binding updates.

## Failures found and resolved

Earlier attempts were blocked before UI execution by Mac lock/LocalAuthentication; two unchanged Keychain checks were previously excluded with `errSecInteractionNotAllowed`. After resume, the Mac became accessible and all of those checks ran successfully. They are not skipped in the accepted Mac command.

The first unlocked run passed ordinary settings persistence but failed advanced JSON and the repository status assertion. Repository access was actually verified: the test read `label`, while native static text supplied `value`. Status/path assertions now use the observed native accessibility value; folder relaunch/removal passes.

The advanced editor failed because automatic quote substitution changed straight quotes to curly quotes when editing committed. The initial native text-value assertion did not detect the later substitution. An exact deterministic decoder reproduction passed; temporary action/bound-text diagnostics exposed the curly quotes. The plain-text native editor fixes the behavior, and the original invalid → valid → apply → save → relaunch scenario now passes. Temporary diagnostics were removed. A further native unit test preserves quotes, dashes and binding contents and rejects unrelated notifications.

Initial compile failures (missing Runtime import, test actor isolation, XCTest query misuse) and earlier runs are retained as historical evidence, not counted as accepted runs. Important intermediate logs/bundles: `mac-ui-resumed`, `mac-ui-diagnostics`, `mac-json-regression`, `mac-ui-json-inspection`, `mac-ui-json-category`, `mac-ui-json-binding`, `mac-ui-json-action`, `mac-ui-plain-json` and `mac-ui-compact`. Earlier `mac-ui-final` records the lock failure. Recordings may include other display content; only AgentDesk window captures are used for visual acceptance and no generated evidence is tracked.

## Remaining product and validation scope

The user's 32-inch 4K, 27-inch 2K, 16-inch 4K and 14-inch 4K targets are preserved in AGENTS.md and the [display matrix](testing.md#mac-display-and-window-matrix). Layout uses logical points and native scaling. Physical diagonal is not a layout breakpoint. The 2K profile includes 2048×1080 and 2560×1440 until the exact panel is known. Physical display/scaling changes, cross-display moves and the full hardware matrix remain final acceptance work. The read-only display inventory exposed no display records in this tool session; that does not establish that no monitor is connected. Existing fixed-size editors/background columns remain a P1-14/P1-15 audit.

The supplementary legacy `Scripts/check-foundation-sources.py` fails with `no such module AgentDeskRuntime`, because it builds only Core/Design before checking the expanded app. It generates no success result. Repair or retire this old supplementary checker in validation-tooling acceptance; native Xcode checks above build the actual dependency graph. Existing SQLite fixture teardown diagnostics remain as recorded in [P1-13b](p1-13b-validation.md), without assertion failures.

The full iPhone device/runtime matrix remains deferred by the user. No live run console, mobile pairing or later phase is implied by this task. Preserve the unrelated Xcode project normalization, personal scheme metadata and `continue-in-updated-project.md` wording outside this commit.

## Reproduce accepted checks

Use fresh result-bundle paths on a rerun. All commands run from the repository root; test stdout/stderr were redirected to matching `.log` files.

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-13c1/mac-accepted.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -only-testing:AgentDeskUITests/ProjectSetupUITests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p1-13c1/iphone-plain-editor.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build
codesign --verify --deep --strict --verbose=2 TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app
codesign --verify --strict --verbose=2 TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app/Contents/XPCServices/AgentDeskCodexHost.xpc
python3 Scripts/validate-documentation.py
git diff --check
```
