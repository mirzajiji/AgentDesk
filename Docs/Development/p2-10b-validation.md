# P2-10b — Native Bug Registry

Implemented and validated, 2026-09-11.

Scope: trusted local Mac registry browsing/editing, explicit sanitized review, manual ticket associations, immutable versions and scoped relationship navigation. Duplicate/report review is P2-10d; external ticket publication remains behind later integration policy gates.

Validation outputs belong under ignored `TestResults/p2-10b/`. Failed attempts are retained below alongside their successful fixes.

- `registry-search.log`: 16 Core registry tests passed, including literal title/behavior/details/ticket/UUID search and incoming relationship filters.
- `models.xcresult`: initial native model checks passed for exact sanitized review, cancellation, ticket link/unlink history, scoped navigation, invalid observation and stale publication.
- `views.log`: failed build due to a combined SwiftUI `@State` declaration. Split the fields into individual declarations.
- `views-fixed.xcresult`: native model, command and responsive layout checks passed.
- `core-final.log`: all 193 Core tests passed.
- `native-ui.xcresult`: both native UI scenarios passed cancellation, bidirectional blocked-link navigation, ticket link/unlink history, relaunch and archive. The run also exposed a failing precision fixture using 29 digits, exceeding the existing strict JSON limit of 28. The corrected fixture tests a supported 28-digit value and passes in `compact-final.xcresult`.
- `compact-final.xcresult`: 15 passed, zero failures/skips, including all five model tests (corrected precision and incoming pagination), seven layout tests, two command tests and compact ticket/history/archive UI. Visual inspection found the sheet's lower edge could extend beyond the parent despite reachable buttons. The new bug sheets now derive their height from the actual presenting view; stricter boundary evidence follows.
- `observed-ui.xcresult`: explicit source-declaration UI passed. An observed assessment without observed provenance cannot reach Publish; adding a user-attested source permits reviewed local publication.

- `window-bounds.xcresult`: the stricter short-window assertion failed because a max-height hint still let the AppKit sheet extend below the window.
- `window-bounds-fixed.xcresult`: eight passed, zero failures/skips, after using an explicit measured height with attachment clearance. The browser, review and nested JSON sheet fit a short native window; the exported app-window screenshot was visually inspected and the entire footer/bottom edge is visible. Seven native layout tests cover logical sizes 600×480 through 3840×2160 with display scales 1/2 and normal/enlarged text. These are not physical-display claims.
- `iphone-final.xcresult`: all 334 tests passed, zero failures/skips, on iPhone 16 Pro, iOS 26.0 (23A343), UDID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. This is an actual local Simulator test run.
- Documentation integrity, coverage, local links, ignore rules and whitespace checks passed. Existing synthetic SQLite fixture-teardown warnings remain recorded; they are not claimed resolved by this task.

The Mac browser/editor now supports scoped command routing, literal search, status/environment/registration filters, immutable history, reviewed manual ticket association and archive, direct and inverse relationship navigation, explicit source declarations, and structured details/evidence edits. Ordinary edits preserve exact requirement creation references. Comparison decisions cannot be altered through the generic JSON editor. A supplied HTTPS ticket can be opened only by the user's explicit link action; saving a registry version performs no external publication.

## Commands and platform

macOS 26.5.2 (25F84), arm64, Xcode 26.0 (17A324). Final physical-display and multi-device/runtime acceptance remains deferred as requested. Swift tests use isolated synthetic stores; UI tests use unique synthetic app containers.

```sh
swift test --package-path Packages/AgentDeskCore --filter ProjectBugStoreTests
swift test --package-path Packages/AgentDeskCore
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10b/models.xcresult -only-testing:AgentDeskTests/NativeBugModelTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10b/views-fixed.xcresult -only-testing:AgentDeskTests/NativeBugModelTests -only-testing:AgentDeskTests/NativeCommandCatalogTests -only-testing:AgentDeskTests/MacEditorLayoutTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10b/native-ui.xcresult -only-testing:AgentDeskTests/NativeBugModelTests -only-testing:AgentDeskTests/NativeCommandCatalogTests -only-testing:AgentDeskTests/MacEditorLayoutTests -only-testing:AgentDeskUITests/BugEditorUITests -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10b/compact-final.xcresult -only-testing:AgentDeskTests/NativeBugModelTests -only-testing:AgentDeskTests/NativeCommandCatalogTests -only-testing:AgentDeskTests/MacEditorLayoutTests -only-testing:AgentDeskUITests/BugEditorUITests/testTicketReviewUnlinkHistoryAndArchiveSurviveRelaunch -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10b/observed-ui.xcresult -only-testing:AgentDeskUITests/BugEditorUITests/testObservedAssessmentRequiresExplicitSourceDeclaration -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10b/window-bounds-fixed.xcresult -only-testing:AgentDeskTests/MacEditorLayoutTests -only-testing:AgentDeskUITests/BugEditorUITests/testBrowserReviewAndJSONStayWithinShortWindow -parallel-testing-enabled NO -test-timeouts-enabled YES -maximum-test-execution-time-allowance 300 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-10b/iphone-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```
