# P2-02 — Native requirement editing and review

Baseline: `6484b5a`, 2026-09-10. Native Mac, iPhone and Release validation passed. This task adds native requirement list/detail/history, explicit editing/review/publication, structured fields, environment selection and scoped command routing. Executable validation rules, test links, general memory/retrieval and bugs remain separate tasks.

## Behavior under validation

Workspaces → project → Requirements, or Command-K → Manage Requirements, opens the selected project's published requirements. The browser separately identifies latest published and active versions. Historical selection does not change either pointer; edits always start from the latest loaded published version and the store revalidates the base before preparing.

The editor collects a readable ID, status, description, change reason and optional configured environments. Advanced JSON edits all structured fields without bypassing validation or review. Review shows every changed field with exact before/after values and the proposed version. Create vN publishes only the reviewed candidate. Cancel writes no version; stale/expired reviews require another review. List values are rendered as JSON in diffs so a multiline single item cannot be mistaken for two items, and an empty list cannot be confused with a literal sentinel string.

The browser distinguishes unavailable storage from a genuinely empty requirement collection. Environment configuration failures preserve stored references and show a setup diagnostic. Native editor actions remain outside scroll areas. Project actions now wrap to additional rows when the five actions do not fit horizontally.

## Checks and findings

Outputs are ignored under `TestResults/p2-02/`.

| Record | Result |
| --- | --- |
| `initial-build.log` / `.xcresult` | Build failed before tests: nonisolated deinit tried to read an actor-isolated Published property. Cleanup now uses a separate stored pending-review handle |
| `model-tests.log` / `.xcresult` | 13 tests passed: eight native requirement model scenarios, three field-diff regressions and two command-catalog tests |
| `native-ui.log` / `.xcresult` | Failed initial UI validation. Four native layout tests passed. Compact project-row test detected clipped Rename after adding Requirements; adaptive action rows address this. Command-route/cancel UI passed. Environment/retirement UI reached reactivation but its String cast of the native checkbox value failed; the assertion now checks the numeric value. History selection after relaunch also failed because row buttons consumed selection; native List selection fixes the behavior |

| `native-fixes.log` / `.xcresult` | 16 passed, zero failures/skips: nine model tests, four layout tests, compact project actions, compact requirement lifecycle and historical viewing |
| `mac-final.log` / `.xcresult` | 383 passed, zero failures/skips: 378 unit/integration tests and five UI tests (three command palette, cancellation and large-window history) |
| `iphone-final.log` / `.xcresult` | 245 passed, zero failures/skips on iPhone 16 Pro, iOS 26.0 (23A343), simulator C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE |

Native runs used Xcode 26.0 and macOS 26.5.2 (25F84), arm64. The iPhone command built the app and ran AgentDeskTests; no iPhone requirement editing UI is claimed. Mac UI fixtures use isolated synthetic containers without provider execution. Compact project/action and review screenshots were exported from native-fixes and visually inspected: wrapped actions and fixed review footer remain visible. Large-window history asserts at least 1300×850 logical points before and after relaunch.

Release Mac build passed; strict deep app signature and strict helper signature verification passed. Documentation integrity/coverage/link/ignore checks and diff whitespace validation passed. Earlier failed commands remain recorded here; later passes must not erase their scope or results.

The physical Mac display and broader iPhone matrices remain full-product acceptance work. Logical size/scale tests and app-window screenshots are narrower evidence.

## Reproduction commands

Run from the repository root. Each test uses a fresh result bundle path.

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-02/mac-final.xcresult -only-testing:AgentDeskTests -only-testing:AgentDeskUITests/NativeCommandPaletteUITests -only-testing:AgentDeskUITests/RequirementEditorUITests/testCommandRouteAndCancelledReviewCreateNoRequirement -only-testing:AgentDeskUITests/RequirementEditorUITests/testReviewedVersionsAdvancedFieldsAndHistorySurviveRelaunch -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-02/iphone-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -configuration Release -destination 'platform=macOS' -derivedDataPath TestResults/p1-13c2/ReleaseMac build
codesign --verify --deep --strict TestResults/p1-13c2/ReleaseMac/Build/Products/Release/AgentDesk.app
codesign --verify --strict TestResults/p1-13c2/ReleaseMac/Build/Products/Release/AgentDesk.app/Contents/XPCServices/AgentDeskCodexHost.xpc
python3 Scripts/validate-documentation.py
git diff --check
```

The focused `native-fixes` run used the same Mac settings with NativeRequirementModelTests, MacEditorLayoutTests, NativeWindowLayoutUITests and the compact lifecycle/history requirement UI cases. Existing synthetic SQLite teardown warnings are not claimed resolved. The unrelated Xcode project normalization, user scheme metadata and continuation-document edit are excluded from this task.
