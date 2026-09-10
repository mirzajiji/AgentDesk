# P2-08 — Duplicate detection and evidence preparation

Implemented and verified, 2026-09-10, with the unrelated native Mac Keychain limitation below. Native management UI remains P2-10.

Implemented so far: pure behavior comparison, explicit blocked/reported/environment/requirement outcomes, and a bounded authoritative registry snapshot. Titles do not establish overlap. Exact comparison includes current requirement references and structured behavior attributes. Unknown attribute names are excluded from diagnostics, with all unknown values considered when explaining differences. Snapshot collection holds the catalog lock across bug heads and active requirement reads, includes archived records, filters the exact environment, and fails on bounds rather than claiming an exhaustive partial search. Its fingerprint detects subsequent registry or active-requirement changes.

These Core APIs are trusted local data access and comparison mechanisms, not runtime authorization, independent observation verification, or permission to create an external issue. The native runtime now authorizes registry reads, verifies referenced artifact/trace identity and sanitized bytes, preserves evidence provenance, redacts review packets and invalidates them on source changes, expiry or access revocation. Review collection is bounded to 32 relevant source records, 128 evidence references and a 32 KiB packet; overflow fails explicitly.

Possible-duplicate reviews can prepare an actual Codex-provider run through the existing coordinator and approval controls. Exact-only comparisons cannot invoke this path. Sanitized comparison content is included in the frozen task and dispatch fingerprint, with source validation at start and again immediately before provider dispatch after repository capture. Provider output remains an interpretation and never updates the registry automatically. Ordinary tests use the same coordinator with its fake provider; no paid/live Codex check is claimed.

The registry now prepares explicit comparison decisions, storing the source and existing immutable revisions, deterministic suggestion, selected resolution and reason in the new bug version. Overrides are identifiable; prior decisions remain in version history. Ordinary edits preserve this metadata and cannot replace it through the general draft path. Duplicate and related decisions maintain the corresponding relationship. Publication revalidates the complete comparison snapshot under the same lock as the version write, in addition to the normal one-shot review token and revision checks. Reported, blocked and stale incoming findings cannot be promoted through this decision path.

The native runtime can prepare a sanitized additional-evidence draft for a linked ticket, for exact duplicates or a freshly saved explicit duplicate decision. It uses only the selected incoming source, preserves evidence provenance/current requirement versions, rejects unresolved ambiguity or missing tickets, and retains source/ticket/expiry/access validation. This is draft preparation only: there is no external network mutation. Incoming readiness is explicit even when the registry has no other candidates. Native management UI integration remains scheduled under P2-10.

## Checks to date

Platform: local arm64 macOS, Swift 6.2 / Xcode 26.0. Generated outputs are ignored under `TestResults/p2-08/`.

- Initial comparison test build failed on test initializer argument order and one missing `try`; corrected before rerunning.
- `comparison-tests.log`: nine focused comparison tests passed, zero failures.
- `snapshot-tests.log`: 20 tests passed, zero failures (nine comparison and 11 registry tests, including three new snapshot tests).
- `evidence-tests.log`: two runtime tests passed for exact artifact identity/fingerprint, trace support, preserved provider interpretation, scope/agent/environment denial and revoked access.
- `review-tests.log`: five runtime tests passed, adding source redaction, changed-registry invalidation, missing-evidence rejection and authorization before record discovery.
- `ambiguity-tests.log`: seven runtime tests passed, adding approved provider dispatch with the exact sanitized packet, no automatic registry mutation, exact-comparison rejection and changed-source denial before provider start.
- `decision-tests.log`: 23 Core tests passed, adding immutable override history, preservation during ordinary edits, changed-registry rejection at publication and denial of reported-to-duplicate promotion.
- `ticket-tests.log`: ten runtime tests passed, adding selected-source-only ticket drafts, redaction, ticket relinking invalidation, required known tickets, explicit local duplicate decisions and empty-candidate readiness.
- `binding-tests.log`: two tests passed for denied collection and source changes during repository baseline capture before provider dispatch.
- `core-final.log`: full Core suite, 185 passed, zero failures. Includes requirement changes between decision preparation/publication.
- `runtime-final.log`: full Runtime suite, 145 passed, zero failures. Includes collector bounds and cancellation.
- `mac-final.xcresult`: 476 passed, two failed, zero skipped on macOS 26.5.2 (25F84), arm64. Both failures are the existing `KeychainIntegrationTests` round-trip and scope-separation tests, reporting `keychain(-25308)`; all other native tests passed. `security error -25308` reports “User interaction is not allowed”; `security show-keychain-info` reports the login keychain has no timeout. No keychain contents or secret values were read or changed. A focused recheck is recorded separately.
- `mac-keychain-recheck.xcresult`: the same two existing tests failed again with `keychain(-25308)`. The Keychain implementation/tests were unchanged by this task. The full Mac suite is not claimed green; native interactive Keychain access needs restoration and revalidation before acceptance that depends on it.
- `iphone-final.xcresult`: 326 passed, zero failures/skips on AgentDesk iPhone 16 Pro, iOS 26.0 (23A343), UDID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.
- `git diff --check` passed at this checkpoint.
- Documentation integrity, 159-section coverage, local links and ignore rules pass. No new UI, physical-display, full-device-matrix, live Codex or external issue action is claimed.

```sh
swift test --package-path Packages/AgentDeskCore --filter BugComparisonTests
swift test --package-path Packages/AgentDeskCore --filter 'BugComparisonTests|ProjectBugStoreTests'
swift test --package-path Packages/AgentDeskRuntime --filter 'BugReviewServiceTests|BugEvidenceTests'
swift test --package-path Packages/AgentDeskCore
swift test --package-path Packages/AgentDeskRuntime
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-08/mac-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p2-08/mac-keychain-recheck.xcresult -only-testing:AgentDeskTests/KeychainIntegrationTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p2-08/iphone-final.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```

Native decision-management UI and its administrative publication wiring belong to P2-10; the runtime must not gain write authority merely by enabling read-only Codex runs. The unrelated Xcode normalization, user scheme metadata and handoff wording changes are excluded from this task's commit. P2-11 acceptance must revisit the native Keychain access failures alongside the full Phase 2 scenarios.
