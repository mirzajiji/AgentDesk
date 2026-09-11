# P2-10d — Native duplicate and report review

Complete implementation and focused acceptance; historical attempts below retain their original results.

Native review now supports authorized current evidence, explicit duplicate/related/distinct decisions, existing-ticket evidence drafts, CityPay reports/grouping and separately approved Codex ambiguity runs. No external ticket mutation is performed.

Final evidence: 148 Runtime tests passed; 518 Mac tests ran with 516 initially passing and both locked-session Keychain failures passing on the unlocked rerun; 337 iPhone 16 Pro / iOS 26.0 tests passed. All three native duplicate-review scenarios passed across `duplicate-authorized.xcresult` (two) and `report-toggle.xcresult` (one). Explicit app-window screenshots were inspected for decision actions, ticket draft, ambiguity results and the report draft. Requirements spacing also passed its native regression. Physical display and full device matrices remain final-project acceptance work. Documentation and diff checks pass.

## Evidence

- `TestResults/p2-10d/review-validation.log`: the first fixture failed with `busy`, correctly enforcing one execution owner per project. The transfer check now closes the original owner before opening its replacement.
- `review-validation-fixed.log`: all nine Runtime bug-review tests passed, zero failures, including current/stale review validation and rejection of tokens transferred to a replacement service.
- `model-build.xcresult`: native Mac build succeeded and six existing bug model tests passed. This compiles the new review model but does not claim dedicated behavior or native UI coverage for it.

Platform: macOS 26.5.2 (25F84), arm64, Xcode 26.0. No new iPhone run is claimed for this incomplete task. All outputs are under ignored `TestResults/p2-10d/`. P2-10c remains the last completed task.

```sh
swift test --package-path Packages/AgentDeskRuntime --filter BugReviewServiceTests
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-10d/model-build.xcresult -only-testing:AgentDeskTests/NativeBugModelTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```

## Read-only review opening and native entry point

`NativeRunService.openReview` opens the real policy/evidence boundary without Codex installation or login. Its requester and reviewer authorities contain only `readEvidence`; a defensive execution boundary also refuses execution. This is a deterministic review session, not a fallback AI provider. The future explicit ambiguity action must open an execution-authorized session and refresh its review.

- `review-only.log`: all ten Runtime review tests pass, including successful review with no execution provider and denied run preparation.
- `context-view-build.xcresult`: initial build failed due to a missing Security import; the view builder for the additional action was also corrected.
- `context-view-fixed.xcresult`: corrected native build succeeded and six existing bug-model tests passed. This compiles the new screen/session; dedicated lifecycle and live UI acceptance remain pending.

The native screen provides context selection, refresh, readable comparison classifications/field differences and disclosure of the centrally sanitized evidence packet. Richer evidence presentation and remaining decision/report actions are still part of this task.

## Exact comparison decisions

Prepared decisions retain the original review's registry store and snapshot. Preparation redacts the supplied reason, then creates an exact Core administrative proposal. Publication revalidates service ownership, authority, current evidence and registry revisions before the Core store performs its atomic reviewed write. Cancellation and replay fail closed. These trusted native administrative APIs are not agent/mobile mutation capabilities and do not expand the review session's execution authority.

The native comparison rows now offer duplicate/related/distinct choices with a required reason. Review shows the exact revisions and reason; Save Reviewed Decision uses the retained proposal. Model refresh/close discards pending proposals.

- `decision-service.log` and `decision-store-bound.log`: 11 Runtime review tests passed, including cancelled/stale/replayed decision rejection and exact publication.
- `decision-view.xcresult`: first build caught nonisolated cleanup accessing a published property. A separate retained token now supports safe cleanup, matching the existing editor pattern.
- `decision-model-fixed.xcresult`: seven native model tests passed, including the new save/cancel/stale-context scenario.
- `decision-store-native.xcresult`: final native build and dedicated decision model test passed against the store-bound API.

Known-ticket evidence drafts, CityPay report/group controls, explicit Codex ambiguity execution, richer evidence presentation and dedicated native UI/lifecycle acceptance remain incomplete. No task commit or new iPhone run yet.

## Native report and known-ticket drafts

The native model now prepares known-ticket evidence additions and CityPay reports through the service-bound review. The report form requires explicit component, region, area and module, and allows selected observations plus a shared problem title for grouping. Runtime validation still rejects unresolved duplicates, missing/currently unavailable requirements, registered group members and incompatible roots. Registered candidate identities are exposed for the ticket-addition control without exposing raw ticket contents.

Draft text is centrally sanitized. The Copy Reviewed Draft button revalidates the current project context, original review and draft before writing to the local clipboard; failed validation clears the prepared draft. No external ticket creation/update or messaging occurs. Refresh, cancellation and decision preparation discard prior drafts.

- `draft-models.xcresult` and `draft-view.xcresult`: two dedicated native model tests passed and the wired report form builds. Tests cover exact decision review, cancellation/stale context, report and ticket draft preparation, redaction, registry changes and ticket relinking before copy release.
- `draft-runtime.log`: 12 affected Runtime comparison/report tests passed.
- Documentation and diff checks pass. No dedicated live UI or new iPhone acceptance yet.

Current remaining work: explicit Codex ambiguity preparation/approval/results, richer readable evidence presentation, session lifecycle tests, native UI/layout acceptance, affected platform suites and final documentation. P2-10d remains uncommitted.

## Explicit Codex ambiguity and structured evidence

Ambiguous comparisons now open the existing native run console after releasing the read-only review lease. The selected agent/environment are carried into a fresh context review. NativeRunSession opens its normal execution service, rebuilds the comparison with that service, and prepares the existing policy-bound ambiguity operation. The console displays the exact bug comparison snapshot before approval. Normal approval, cancellation, saved output, provenance and context-change monitoring remain in use. Codex output is interpretation and never saves a bug decision or mutates tickets automatically.

Native evidence presentation decodes only the already-redacted service packet. It separates incoming/existing findings, source statements, current requirement fields and saved artifacts with observed/interpretation provenance. Recorded user resolutions are displayed separately from deterministic suggestions; historical reason text is not newly exposed through the runtime interface.

- `ambiguity-session.xcresult`: an assertion assumed comparison text lived in the general input snapshot. The dedicated `bugReviewSnapshot` was already bound to the run; the UI had not exposed it. The assertion now checks that exact snapshot, which the console explicitly displays.
- `ambiguity-session-fixed.xcresult`: 11 native session/model tests passed. Includes no dispatch before approval, sanitized comparison input, unchanged registry after Codex interpretation and blocked dispatch after registry changes. Uses fake providers, not live Codex/company access.
- `evidence-view.xcresult`: initial build caught an unhandled throwing requirement-field conversion. The view now displays an unavailable state on conversion failure.
- `evidence-view-fixed.xcresult`: native build and two dedicated model tests passed, including redacted evidence/current requirement decoding and recorded user resolution after publication.

Current remaining gate: native review-session lifecycle tests, dedicated live UI/layout acceptance (including read-only-to-Codex ownership transfer), affected full Mac/iPhone suites, final documentation and focused commit/push. No new commit or iPhone coverage is claimed in this increment.

## Lifecycle and live UI acceptance attempt

The review session now serializes cleanup and supports a controlled opener for lifecycle tests. `review-lifecycle.xcresult` passed three tests, including context-change invalidation and successful reopening of the released project lease. The Debug UI fixture adds synthetic requirement/bug pairs only inside the existing UUID-scoped, validated test root; production repository access is unchanged. Read-only UI tests use the real review service and Core stores, and ambiguity tests use the existing fake execution provider.

- `runtime-full.log`: all 148 Runtime tests passed.
- `duplicate-ui.xcresult`: both native UI scenarios failed to activate AgentDesk before exercising the flow. macOS reported `CGSSessionScreenIsLocked = Yes`; this is a blocked UI run, not passing acceptance. The user was asked asynchronously to unlock the session.
- Added logical-size layout coverage for the duplicate-review and ambiguity-console entry views. `mac-full.xcresult` is running; full Mac result pending.

Do not commit P2-10d until the locked-session UI gate is restored and the complete native scenarios, screenshots and platform checks are verified. No product feature is marked complete on the strength of the synthetic fixture alone.

## Full Mac result and Simulator continuation

`mac-full.xcresult` executed 518 tests: 516 passed and two existing native Keychain integration tests failed with `keychain(-25308)` (interaction not allowed while the session was locked). The new review models, lifecycle, ambiguity session and logical-size layout tests passed. This is not an all-green Mac acceptance claim; recheck the two Keychain tests after unlock together with the blocked UI scenarios.

`iphone.xcresult` passed all 337 tests on the primary iPhone 16 Pro / iOS 26.0 simulator. There is no Git or code-writing blocker; the native UI/Keychain gate currently needs an unlocked macOS session.

## Latest build and Requirements inspection

`latest-build.log`: macOS `xcodebuild build-for-testing` succeeded, including the third duplicate-report UI scenario and its accessibility identifiers. This compiles tests; it does not establish UI acceptance. The Requirements browser retains its existing top-leading alignment and 20-point padding; prior four-state spacing validation is recorded in `p2-03a-validation.md`. A fresh visual recheck remains blocked because macOS still reports the session locked. No new padding defect or fix is claimed without reproduction.

## Unlocked-session acceptance rerun

The resumed session no longer reports a screen lock. `unlocked-acceptance.xcresult` runs the Requirements spacing regression, three duplicate-review UI scenarios and the two native Keychain integration tests. Both Keychain tests passed (2 tests, zero failures), resolving the earlier interaction-not-allowed failures. The process finished with exit 65: the UI runner timed out enabling automation mode before executing scenarios. No UI acceptance is claimed.

The local `/usr/bin/automationmodetool --help` diagnostic reported: “Automation Mode is disabled” and “This device requires user authentication to enable Automation Mode.” The screen lock is resolved, but macOS authentication for automation remains required. No authentication settings were changed and no credentials were requested.

## Authorization restored and Requirements rechecked

`authorization-retry.xcresult` passed the native Requirements spacing regression (one test covering empty and populated/unselected states at compact and larger attained window sizes). Exported explicit app-window screenshots of the compact empty and unselected states were visually inspected: the header retains its normal top inset, with no large gap above the title. This verifies the existing fix; no speculative padding change was made. The three duplicate-review UI scenarios are now executing in `duplicate-authorized.xcresult`; their result remains pending.

## Selected bug title spacing correction

The user clarified that the issue is in Bugs after selecting a record. `selected-bug-spacing.xcresult` reproduced a 114-point offset from the detail viewport to its title: narrow-width version/actions stacked above it. The explicit app-window screenshot was inspected. The title now precedes the adaptive controls. `selected-bug-spacing-fixed.xcresult` passed the native regression, requiring the registry header within 40 points of the sheet top and the selected title within 36 points of the detail viewport. This is distinct from the previously verified Requirements view.

The report disclosure interaction remains unresolved: `report-disclosure.xcresult` and `report-triangle.xcresult` failed before the component picker appeared. Accessibility evidence shows the disclosure remained collapsed. No report UI acceptance is claimed. The two other duplicate UI scenarios passed in `duplicate-authorized.xcresult`; explicit app-window captures of their draft, decision and ambiguity result were inspected.

## Report expansion and complete report scenario

Replaced the report disclosure with an explicit native button and local expansion state, including an Expanded/Collapsed accessibility value. `report-toggle.xcresult` passed the full native scenario: unresolved duplicate blocks a draft, an exact Distinct decision is reviewed and saved, then the report form prepares a draft and exposes the validated copy action. The prior failed disclosure interactions remain recorded above. All three duplicate-review scenarios now have passing results across the focused runs. Final screenshot inspection and focused commit review remain outstanding.
