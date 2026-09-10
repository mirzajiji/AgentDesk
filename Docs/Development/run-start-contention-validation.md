# Native run-start contention investigation

Date: 2026-09-10. Baseline `2cd7ceb`. This is the focused P1-13c3 regression task; implementation and affected validation are complete.

The P1-14a large-window diff UI check intermittently remained at `waitingForApproval`. A three-iteration diagnostic run reproduced an erroneous source-change report. Native context validation and its monitor read multiple catalog-backed actors, each taking the existing nonblocking exclusive directory lock. Overlapping readers can return `CatalogError.busy` even with unchanged files; the session previously reported every monitoring failure as changed sources.

A deterministic regression holds the real directory lock for 40 ms while validating an unchanged reviewed context. It fails before the change (`lock-red.log`) and passes afterward (`lock-green.log`). Preview now retries only `CatalogError.busy`, restarting both complete observations each time, with at most four cancellable 20 ms sleeps. Changed snapshots, invalid sources and scope failures are not retried or accepted. Persistent contention remains an error. The native console distinguishes busy configuration from changed/unverifiable sources; raw errors and source text are not exposed.

Checks under ignored `TestResults/p1-15-start-investigation/`:

- `repeated.log`: 25 approve/start cycles with live observation passed before the fix; this narrower test did not reproduce the UI failure.
- `diagnostic-ui.log`: repeated pre-fix UI execution reproduced a source-verification failure. This is a failed test run, not acceptance evidence.
- `lock-red.log`: the new transient-lock regression failed before the fix.
- `lock-green.log`: affected setup and native session tests pass, including transient/persistent locks, cancellation, actual source changes, and 25 reviewed starts.
- `mac-final.log`: 339 native Mac unit/integration tests and the large-window diff UI test passed, including actual Keychain coverage.
- `iphone-final.log`: 228 actual iPhone 16 Pro tests passed on iOS 26.0, device `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.
- `ui-repeat-final.log`: all three native diff/start iterations passed after the fix.

Documentation integrity/link checks and diff checks passed before commit.

Existing SQLite fixture-teardown warnings remain unrelated to the lock regression. The physical Mac display matrix and broader iPhone matrix remain final-product acceptance work.

## Reproduction

On macOS 26.5.2 / Xcode 26.0, run `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -parallel-testing-enabled NO -only-testing:AgentDeskTests -only-testing:AgentDeskUITests/ProjectRunConsoleUITests/testSavedDiffPreservesLinesInLargeNativeWindow test`. Repeat the UI selector alone with `-test-iterations 3` to exercise preparation, explicit approval, start and saved diff presentation. The deterministic failing/passing regression is `AgentDeskTests/ProjectExecutionSetupTests/testTransientCatalogLockDoesNotInvalidateUnchangedReviewedContext`.

For iPhone, use `-destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -only-testing:AgentDeskTests`. Each recorded run also used a unique `-resultBundlePath` under the evidence directory. Documentation checks use `python3 Scripts/validate-documentation.py` and `git diff --check`.
