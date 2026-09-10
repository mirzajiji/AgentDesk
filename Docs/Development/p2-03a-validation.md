# P2-03a — Requirements modal top spacing

User-reported regression, 2026-09-10. Baseline: `d345947`. Implemented and verified.

Opening Requirements with no records placed the header 181.75 logical points below the sheet's top. The outer resizable frame centered an intrinsically sized content stack. The browser now fills the sheet with top-leading alignment, while unavailable/empty/unselected content fills the remaining body. Header and primary controls retain the standard inset in short and tall windows.

The native UI regression measures header-to-sheet distance (12–36 points) for empty and populated/unselected views in compact and large windows. It creates and publishes a synthetic requirement between states. Existing native layout tests exercise actual SwiftUI views across logical sizes, display scales and Dynamic Type proposals.

## Evidence

Ignored outputs: `TestResults/p2-03a/`.

- `modal-baseline.log` / `.xcresult`: native UI test failed at 181.75 points. The app-window screenshot was exported and visually inspected, confirming the large blank area above the header.
- `modal-fixed.log` / `.xcresult`: five passed, zero failures/skips: four native layout tests and the four-state UI regression. Header inset stayed within 12–36 points. Corrected empty and compact unselected app-window screenshots were exported and visually inspected.
- Documentation integrity, coverage, local links, ignore rules and diff whitespace checks passed.

Platform: macOS 26.5.2 (25F84), arm64, Xcode 26.0. This change is entirely within macOS views/tests. Shared business logic and the iPhone app are unchanged; no new iPhone run is claimed. Physical display acceptance remains deferred as requested.

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-03a/modal-fixed.xcresult -only-testing:AgentDeskTests/MacEditorLayoutTests -only-testing:AgentDeskUITests/RequirementEditorUITests/testRequirementBrowserHeaderStaysAtTopInEmptyAndUnselectedStates -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
python3 Scripts/validate-documentation.py
git diff --check
```
