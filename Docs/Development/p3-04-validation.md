# P3-04 — Reviewed Jira mutations and bug integration

Status: in progress. Reviewed comment dispatch, known-ticket evidence additions, comment reconciliation, and summary/description issue-edit dispatch are implemented with synthetic tests. Issue creation/deletion, attachment writes, native mutation controls, and full acceptance remain incomplete. No live external ticket/comment/edit has been created.

The checkpoints below are chronological; limitations stated in earlier checkpoints describe that checkpoint and are superseded only by explicit later validation.

The first component is a scoped sanitized comment draft. It encodes text deterministically into Jira's document body while preserving blank paragraphs, rejects invalid issue identifiers/empty/oversized content, and binds exact encoded content, issue target, cloud, connection configuration, permissions and run to the existing prepared-action policy boundary. A prepared draft never grants network authority.

The [official Jira comment API](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-comments/) was checked on 2026-09-11: comment creation uses the issue comment POST route, document-formatted body, write permission/scope and a 201 response. Existing read-only OAuth registration must not be presented as having write access.

`swift test --package-path Packages/AgentDeskPlugins` passed 63 tests, zero failures (`TestResults/p3-04/comment-draft.log`). The new test checks document/blank-paragraph structure, deterministic approval identity, changed body/target/cloud bindings, foreign-run rejection and malformed inputs. `git diff --check` passed. Native validation remains to run after transport/policy integration. Issue mutations, attachments, duplicate/current-requirement integration, durable dispatch and ambiguous-response handling remain incomplete.

Added the internal comment POST request builder and response classifier. Requests require both token and selected-site write scopes, unexpired credentials and the exact prepared document body. A valid bounded 201 receipt with a numeric comment ID is centrally redacted. Explicit request/auth/permission/size/rate rejections are distinguished from uncertain outcomes; other statuses and malformed successes remain unknown and must not be blindly retried.

`swift test --package-path Packages/AgentDeskPlugins` passed 65 tests (`TestResults/p3-04/comment-write.log`). New tests cover both scope grants, expiry, fixed route/body, sanitized receipts, known rejection statuses and malformed/ambiguous responses. `git diff --check` passed. This checkpoint constructs/decodes requests only: transport dispatch, durable reconciliation and policy/bug integration remain unfinished. No live write occurred.

Added internal session comment dispatch with exact prepared-action reconstruction, scope/run checks, current persisted grant validation and outbound re-redaction using active credentials. A draft that would change under the stronger redactor is rejected for re-review rather than silently rewritten. Transport errors after entering send are conservatively unknown, including cancellation; no internal retry occurs. Mutation methods remain internal and are not advertised as available capabilities pending runtime policy/durable-dispatch integration.

`swift test --package-path Packages/AgentDeskPlugins` passed 66 tests (`TestResults/p3-04/comment-session.log`). A synthetic URLProtocol test verifies changed content and credential echoes cause zero requests, valid dispatch returns a receipt, and connection loss produces one attempted send with an unknown outcome. `git diff --check` passed. These fixtures bypass the future runtime wrapper explicitly for internal transport testing; no external write or full policy acceptance is claimed.

Connected comment execution to `PluginPolicySession`. The wrapper requires an explicit approval ID even under a general allow policy; the existing policy gate validates and durably consumes the exact reviewed action before the session can send it. Replaying that consumed review does not dispatch again. Public session transport entry points follow the existing trusted-runtime boundary and do not themselves replace policy authorization. Write capabilities remain undiscoverable until the rest of mutation setup is integrated.

`swift test --package-path Packages/AgentDeskRuntime` passed all 152 tests (`TestResults/p3-04/comment-policy.log`). The new synthetic comment test verifies denied/unapproved calls send nothing, approved dispatch sends once and replay does not send again. `git diff --check` passed. Restart-specific replay, ambiguous-write reconciliation and bug-review validation remain to integrate; no external Jira mutation occurred.

Extended the comment policy regression to reopen the SQLite approval store and construct a new policy session. It observes the persisted consumed state and verifies replay through the new session does not send a second comment. This proves persistence across store/session reconstruction; it is not an OS process-kill test and does not reconcile whether Jira applied an interrupted write.

`swift test --package-path Packages/AgentDeskRuntime --filter JiraPolicyCommentTests` passed one focused test (`TestResults/p3-04/comment-reopen.log`). `git diff --check` passed. The prior full runtime suite remains 152 passing tests; this test-only extension was checked with the focused run.

Added the internal bridge from duplicate-review evidence to a Jira comment draft. It retains the source's current-requirement/duplicate validation closure and enforces scoped configuration and expiry. Automatic ticket resolution requires an exact configured HTTPS site and `/browse/KEY` URL with a consistent key; a bare key cannot establish company/site ownership and is rejected pending explicit native target selection.

`swift test --package-path Packages/AgentDeskRuntime --filter BugJiraCommentTests` passed one focused target-resolution test (`TestResults/p3-04/bug-jira-target.log`). It covers correct sites, URL-only associations, foreign host/port, mismatched keys, encoded paths and extra segments. `git diff --check` passed. Bridge lifecycle/revalidation tests and dispatch integration remain incomplete; no comment was sent externally.

The evidence-to-comment bridge now checks expiry both before and after asynchronous source validation, using an injected clock for deterministic tests. Revalidation preserves stale-source errors and checks cancellation; expiry reached during validation cannot leave an apparently valid prepared comment.

`swift test --package-path Packages/AgentDeskRuntime --filter BugJiraCommentTests` passed two tests (`TestResults/p3-04/bug-jira-revalidation.log`). The new test changes source validity after preparation and advances time during validation, covering both initial preparation and subsequent revalidation. `git diff --check` passed. Dispatch integration remains unfinished.

Added an evidence-specific runtime dispatch method. It validates the retained duplicate/requirement source before approval execution and again through a callback immediately before transport, after credential/redaction checks. Final stale-evidence errors remain pre-dispatch failures rather than unknown remote outcomes. Cancellation, closed-session and token-expiry checks follow that callback.

Focused checks passed: `swift test --package-path Packages/AgentDeskRuntime --filter JiraPolicyCommentTests` (`TestResults/p3-04/comment-dispatch-hook.log`) and `swift test --package-path Packages/AgentDeskPlugins --filter JiraCommentSessionTests` (`comment-stale-evidence.log`), one test each. The transport fixture verifies a stale-source callback results in zero HTTP requests. `git diff --check` passed. Full evidence-wrapper integration, native acceptance and uncertain-result reconciliation remain incomplete.

Final comment preparation now reloads the persisted grant after the asynchronous evidence callback. This closes an observed gap where logout or rotation during evidence validation could leave the already-loaded access token eligible for dispatch. The deterministic fixture deletes the grant inside that callback and verifies authentication expiry with zero HTTP requests, then restores the synthetic grant for the existing success/failure cases.

`swift test --package-path Packages/AgentDeskPlugins --filter JiraCommentSessionTests` passed (`TestResults/p3-04/comment-grant-recheck.log`); `git diff --check` passed. This verifies local pre-dispatch validation, not atomicity between external Jira and independently changing local files.

Extended the durable comment-dispatch test to simulate connection loss after transport starts. The runtime reports an unknown outcome, the approval remains consumed in SQLite, and replay through both the original and a reconstructed session produces no second request. The success path retains the same checks.

`swift test --package-path Packages/AgentDeskRuntime --filter JiraPolicyCommentTests` passed two tests (`TestResults/p3-04/comment-unknown-replay.log`). `git diff --check` passed. This prevents replay of that approval; it does not prove whether Jira applied the request or prevent a separately reviewed new action from creating a duplicate. Explicit reconciliation remains required.

Added an integrated evidence-wrapper dispatch test using a synthetic saved Jira ticket and retained source-validation closure. It verifies validation at bridge preparation, policy entry and final transport dispatch, followed by exactly one approved HTTP invocation; existing consumed-approval replay/reopen checks also apply. This exercises the wrapper integration, while source freshness semantics are separately covered by the bug-review service and bridge tests.

`swift test --package-path Packages/AgentDeskRuntime --filter JiraPolicyCommentTests` passed three tests (`TestResults/p3-04/comment-evidence-integration.log`). `git diff --check` passed. Native user flow, issue/attachment mutations and explicit uncertain-outcome reconciliation remain unfinished.

Native runtime checkpoint passed: 156 tests on macOS 26.5.2/Xcode 26.0 and 75 supported runtime tests on iPhone 16 Pro/iOS 26.0. Commands from `Packages/AgentDeskRuntime`: `xcodebuild -scheme AgentDeskRuntime -destination 'platform=macOS' -derivedDataPath ../../TestResults/p3-04/RuntimeMac -resultBundlePath ../../TestResults/p3-04/runtime-mac.xcresult -parallel-testing-enabled NO test`; and the corresponding simulator destination `platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`, derived data `../../TestResults/p3-04/RuntimeIPhone`, result `../../TestResults/p3-04/runtime-iphone.xcresult`. Mac-only runtime tests are not counted as iPhone coverage. These are native package runs, not UI acceptance or live Jira tests.

Documentation validation passed 159 sections, 103 Markdown files and 473 local links; diff checks passed. P3-04 remains incomplete: remaining mutation operations, user-facing reconciliation, native flow and final acceptance are still pending.

Comment dispatch now rechecks the prepared policy/configuration and authority generation on both sides of the asynchronous evidence callback. Authority removal during that callback invalidates the invocation before transport. The review remains consumed, requiring a fresh review if authority is later restored.

`swift test --package-path Packages/AgentDeskRuntime --filter JiraPolicyCommentTests` passed three tests (`TestResults/p3-04/comment-authority-race.log`). Each scenario now revokes authority inside a final-dispatch callback and verifies no additional HTTP request. `git diff --check` passed. The previous native checkpoint predates this refinement; affected native validation remains to rerun before committing the task.

Added bounded exact-body candidate comparison for observed comment pages. It preserves all matching comment IDs and page continuation, rejects cross-run/scope evidence, and deliberately exposes no success/absence/retry verdict: matching content may be unrelated and no match does not prove the attempted write failed. The internal caller must supply a page from an authorized read of the exact target; target-bound read integration and user review remain pending.

`swift test --package-path Packages/AgentDeskPlugins --filter JiraCommentReconciliationTests` passed one test (`TestResults/p3-04/comment-candidates.log`), covering multiple identical candidates, changed text, page continuation and foreign-run rejection. `git diff --check` passed. No reconciliation network request or external mutation occurred.

Added session reconciliation through the existing exact prepared comment-page read. The session derives the issue from the original draft and validates the requested offset/limit, scope, credentials and read identity before obtaining the observed page. Candidate comparison therefore no longer requires a caller to supply an arbitrary page on this path.

`swift test --package-path Packages/AgentDeskPlugins --filter JiraCommentSessionTests` passed (`TestResults/p3-04/comment-reconcile-read.log`): changed page and foreign issue cause no request, while the bound synthetic read returns a matching candidate. `git diff --check` passed. Runtime read-policy wrapper and user-facing reconciliation review remain pending. Matches still do not prove authorship or authorize retry.

Connected reconciliation to its own `commentsRead` runtime policy invocation. The original write approval grants no read authority: denial, required review and durable consumption follow the existing read gate before the exact target/page session read. Candidate comparison remains non-authoritative about whether an earlier write succeeded.

`swift test --package-path Packages/AgentDeskRuntime --filter JiraPolicyReconciliationTests` passed (`TestResults/p3-04/reconcile-policy.log`). Synthetic transport checks deny/unapproved zero-dispatch, one approved read and consumed-review replay rejection. `git diff --check` passed. User-facing reconciliation and remaining mutation capabilities remain unfinished.

Added explicit OAuth access selection to support reviewed writes: registration defaults to read-only and may request read/write consent. The native client sends that selection and validates the exact corresponding authorization scopes. The broker accepts only `read` or `write` (omission preserves prior read-only behavior), and adds `write:jira-work` only for the latter. OAuth consent does not grant runtime mutation authority; each write still requires exact review and both returned token/site write scopes.

Host SwiftPM checks passed: 68 plugin tests (`TestResults/p3-04/write-consent-native.log`) and 22 broker tests (`write-consent-broker.log`). New cases reject an unexpected write authorization URL for a read-only request and arbitrary broker scope choices. `git diff --check` passed. This updates the implementation previously committed in P3-03b as required by P3-04; no live consent or credential change occurred. Native selection UI remains P3-05.

Capability discovery now includes the implemented `commentsWrite` operation only when both token and selected-site scopes contain `write:jira-work`. Read capabilities retain their separate two-sided scope check. Issue creation/update/deletion and attachment writes are not advertised because their implementations are still pending. Discovery remains availability metadata; the runtime requires explicit reviewed approval for comment dispatch.

`swift test --package-path Packages/AgentDeskPlugins` passed 68 tests (`TestResults/p3-04/comment-capabilities.log`). Updated discovery tests cover read-only, write-only, mismatched grants and combined grants, with exact capability sets. `git diff --check` passed. Native UI and full P3-04 acceptance remain incomplete.

Started issue editing with explicit summary/description replacement drafts. Omitted fields remain omitted; an explicitly empty description produces an empty document. Drafts enforce one scope/run, bounded single-line summaries and descriptions, and bind the caller's observed-issue fingerprint alongside the exact fields for later preflight validation. The plain-text document encoder is now shared with comments, preserving their existing representation. Transport and actual observed-state revalidation are not implemented yet, so this fingerprint alone does not prevent concurrent Jira edits.

The official [issue API](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/) and [v3 introduction](https://developer.atlassian.com/cloud/jira/platform/rest/v3/intro) were checked for field update/document format; direct retrieval of the large issue page hit a tool size limit, so its official search excerpt was used. The 255 UTF-16-unit summary limit is AgentDesk's conservative input bound.

`swift test --package-path Packages/AgentDeskPlugins` passed 69 tests (`TestResults/p3-04/issue-edit-draft.log`). New tests cover omission versus clearing, exact observed-state/field approval binding, empty edits, invalid summary sizes/newlines and mixed-run content. `git diff --check` passed. No issue update was sent.

### Issue-edit HTTP boundary

Added the internal exact PUT request builder for the reviewed summary/description draft. It requires both token and selected-site write grants and an unexpired credential. No override flags or returnIssue query are sent. Only an empty 204 is acknowledged; explicit rejection statuses remain distinct from unexpected or uncertain responses. This acknowledgment does not prove a subsequent read or atomic compare-and-swap. Session dispatch, observed-state preflight, and runtime review integration remain incomplete, so issue editing is not advertised as an available capability.

Response semantics checked against [Atlassian's issue API](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/). Validation: `swift test --package-path Packages/AgentDeskPlugins` — 71 tests passed on macOS, including request grant/expiry and response classification regressions. Log: `TestResults/p3-04/issue-edit-transport.log`. `git diff --check` passed. No live Jira writes or additional Simulator coverage claimed for this checkpoint.

### Scoped issue state comparison

Added an internal edit fingerprint from redacted issue evidence, including the Jira updated value, issue identity, cloud identity, and full redaction scope/run. JSON object ordering and local read timestamps do not invalidate unchanged evidence. Missing revision evidence or inconsistent returned identity fails closed. This comparison is not server-side concurrency control, and it is not yet connected to dispatch. `swift test --package-path Packages/AgentDeskPlugins` passed 72 tests; `TestResults/p3-04/issue-state.log` records the macOS run. Regression coverage checks changed content/revision, cloud/run separation, stable ordering/read time, and invalid evidence. Diff checks passed.

### Authorized issue snapshots

Connected read-derived `JiraIssueSnapshot` to the authenticated Cloud session and runtime issue-read policy wrapper. The session reconstructs the exact read action, verifies scope/run and the persisted grant, and redacts credentials before returning evidence. Snapshot edit construction retains the observed fingerprint and rejects content from another run. The existing plain JSON read result remains available. This does not yet dispatch edits.

Validation: `swift test --package-path Packages/AgentDeskRuntime --filter JiraPolicyIssueSnapshotTests` passed its synthetic deny/approval/replay and snapshot-to-draft test (`TestResults/p3-04/issue-snapshot-policy.log`). `swift test --package-path Packages/AgentDeskPlugins` passed 72 tests, including foreign-run draft rejection (`TestResults/p3-04/issue-snapshot-plugin.log`). Both are macOS host runs; native device checks remain due before the feature commit.

### Issue-edit dispatch integration

Added exact prepared edit dispatch, credential-aware draft revalidation, read-derived scope/cloud/identifier/fingerprint comparison, read-time checks, final authority callback, and a post-callback persisted-grant check. The runtime supplies a separate issue-read policy session and requires an explicit write approval ID; a dry-run read cannot authorize a write. Transport uncertainty remains non-retryable automatically. Jira can still change between the read and PUT; no server-side conditional-update guarantee is claimed.

`swift test --package-path Packages/AgentDeskPlugins` passed 73 tests (`TestResults/p3-04/issue-edit-session.log`). The new synthetic session regression exercises baseline mismatch, revoked authority, and fresh GET then acknowledged PUT. Runtime compiled and the snapshot policy regression passed (`TestResults/p3-04/issue-dispatch-build.log`). Write-policy integration, replay/failure coverage, native runs, and feature review remain due before commit. No live Jira mutation was made.

### Reviewed edit replay regression

The runtime edit regression now exercises an unknown approval (no HTTP), an approved fresh read followed by acknowledged PUT, an uncertain PUT failure, and replay through reopened SQLite approval storage after both outcomes (no further HTTP). Synthetic URLProtocol fixtures only. `swift test --package-path Packages/AgentDeskRuntime --filter JiraPolicyIssueEditTests` passed (`TestResults/p3-04/issue-edit-policy.log`), followed by the full runtime suite: 159 tests passed (`TestResults/p3-04/runtime-edit-full.log`). These are macOS host results, not Simulator results. Diff checks passed. Native validation and remaining P3-04 capabilities are still outstanding.

### Native runtime validation after edit integration

On macOS 26.5.2 / Xcode 26.0, `xcodebuild -scheme AgentDeskRuntime -destination 'platform=macOS' -derivedDataPath ../../TestResults/p3-04/RuntimeMac -resultBundlePath ../../TestResults/p3-04/runtime-edit-mac.xcresult -parallel-testing-enabled NO test` passed 159 tests. From the same package directory, `xcodebuild -scheme AgentDeskRuntime -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-04/RuntimeIPhone -resultBundlePath ../../TestResults/p3-04/runtime-edit-iphone.xcresult -parallel-testing-enabled NO test` passed 78 supported tests on iPhone 16 Pro / iOS 26.0. Matching `.log` files accompany both result bundles.

Both native logs contain SQLite test cleanup warnings about databases unlinked while still open. Tests passed, but these warnings remain a fixture-lifecycle concern and are not a clean-log claim. `python3 Scripts/validate-documentation.py` passed: 159 sections, 103 Markdown files, 473 local links, ignore-rule checks. Full application builds, remaining mutation capabilities and feature commit review are still outstanding.

### Application integration builds

Both application builds passed after the issue-edit integration: `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build` and the equivalent iPhone destination `platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE` with `TestResults/p1-08b/FilteredIPhone`. Logs: `TestResults/p3-04/app-edit-mac.log` and `app-edit-iphone.log`. These builds supplement the actual Simulator runs above. Existing localized interpolation deprecation warnings in BugDuplicateReviewView and skipped AppIntents metadata extraction remain; no clean-warning build is claimed.

The full plugin suite also passed 73 tests on iPhone 16 Pro / iOS 26.0: from `Packages/AgentDeskPlugins`, `xcodebuild -scheme AgentDeskPlugins -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-04/PluginsIPhone -resultBundlePath ../../TestResults/p3-04/plugins-edit-iphone.xcresult -parallel-testing-enabled NO test`. Matching log: `TestResults/p3-04/plugins-edit-iphone.log`. Diff checks passed.

### Independent preflight read authority

Extended the runtime edit test with a valid approved write and a separate read session whose requester lacks read authority. The operation fails with denial and sends neither GET nor PUT. Reusing that consumed write review with a permitted read session still sends nothing. `swift test --package-path Packages/AgentDeskRuntime --filter JiraPolicyIssueEditTests` passed (`TestResults/p3-04/issue-read-denial.log`). This extends test coverage only; production code is unchanged since the native/build checks above.

### Reviewed mutation backend checkpoint

This commit contains the tested comment/evidence and summary/description edit backend, with exact-action review, scoped preflight reads, durable approval consumption, and conservative uncertain-outcome reporting. It is a component checkpoint of P3-04, not completion of that task. Issue creation/deletion, attachment writes, durable user-facing outcome reconciliation, and native mutation flows remain to implement. Full supported issue-edit capability is not advertised yet. OAuth write consent was committed separately as `ee7e71e`.

Reviewed the transport and runtime changes, tests and fixture data. Only synthetic fixtures are included. The three unrelated Xcode/project handoff edits are excluded. Final documentation and staged diff checks passed.

### Durable mutation ledger in progress

Added schema version 7 and a scoped SQLite mutation-attempt store. A begin record is unresolved until an explicit terminal acknowledgment/rejection/not-dispatched result; an interrupted unresolved attempt is never treated as safe to retry. Duplicate begins and terminal rewrites fail, exact action/approval bindings are required, and clock regression is rejected. No response text or credentials enter this ledger. Runtime integration and native validation remain incomplete.

The first persistence run failed four old schema-version assertions (expected 6, actual 7); updated those migration expectations. `swift test --package-path Packages/AgentDeskPersistence` then passed 48 tests (`TestResults/p3-04/mutation-ledger-tests.log`), including reopened storage, duplicate attempts, wrong approvals, terminal immutability, and environment isolation. Initial failure log: `TestResults/p3-04/mutation-ledger-build.log`. No commit for this unfinished integration yet.

### Ledger connected to reviewed dispatch

The policy session now opens a scope-matched mutation ledger from its approval store. After approval consumption, it durably begins the attempt before entering comment/edit dispatch. Acknowledgments and explicit Jira rejections are recorded; other errors conservatively leave unresolved state. Failure to record the outcome is not reported as success. No error text or remote response content is persisted. Approval consumption and ledger begin are separate transactions: interruption between them can consume a review without an attempt record, but cannot dispatch a write through this wrapper.

Seven Jira policy tests passed with `swift test --package-path Packages/AgentDeskRuntime --filter JiraPolicy` (`TestResults/p3-04/mutation-ledger-runtime-final.log`). Edit regressions now reopen the ledger and assert acknowledged versus unresolved outcomes. Initial compile planning missed the new dependency file; cleaning the runtime package refreshed it. A subsequent build was interrupted by a test-file edit; the final run used settled inputs and passed. Native checks and full persistence/runtime validation remain due for this integration.

### Ledger read-integrity review

Full runtime host validation passed 159 tests (`TestResults/p3-04/ledger-runtime-full.log`). Review then added validation of the decoded record's action ID, scope/environment, mutation operation and finite ordered dates before returning stored evidence. A synthetic corrupt-row test verifies matching SQL keys cannot expose a foreign embedded scope. The full persistence suite passed 49 tests (`TestResults/p3-04/ledger-scope-tests.log`). Native runtime validation is being repeated with this additional read check.

The updated runtime passed on iPhone 16 Pro / iOS 26.0: `xcodebuild -scheme AgentDeskRuntime -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-04/RuntimeIPhone -resultBundlePath ../../TestResults/p3-04/ledger-runtime-iphone.xcresult -parallel-testing-enabled NO test`, run from `Packages/AgentDeskRuntime`. Matching log: `TestResults/p3-04/ledger-runtime-iphone.log`. Native Mac and full app build checks remain due for this ledger change.

### Durable ledger checkpoint validation

Native Mac runtime tests passed 159 tests on macOS 26.5.2 / Xcode 26.0: from `Packages/AgentDeskRuntime`, `xcodebuild -scheme AgentDeskRuntime -destination 'platform=macOS' -derivedDataPath ../../TestResults/p3-04/RuntimeMac -resultBundlePath ../../TestResults/p3-04/ledger-runtime-mac.xcresult -parallel-testing-enabled NO test`. The iPhone run above passed 78 supported tests. Existing SQLite fixture-cleanup warnings persist.

Both app builds passed with the ledger: `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build` and the equivalent iPhone 16 Pro Simulator destination with `TestResults/p1-08b/FilteredIPhone`. Logs: `TestResults/p3-04/ledger-app-mac.log` and `ledger-app-iphone.log`. Documentation and diff checks passed. This checkpoint persists operational outcomes; native outcome browsing/reconciliation and the remaining P3-04 operations are still incomplete.

### Mutation history pagination

Added bounded (1–100 records) key-based history pagination, ordered by action UUID. It retains scope/environment predicates and validates embedded record identity on every page. This is not chronological ordering or snapshot isolation: refreshing is required to see later insertions whose keys sort before the cursor. Tests cover three pages without duplicates, page limits and empty foreign-environment results. `swift test --package-path Packages/AgentDeskPersistence` passed 50 tests (`TestResults/p3-04/ledger-pagination.log`). Native history UI and its validation are still pending; no additional native coverage is claimed for this change yet.

### Local-user history authorization service

Added `NativeMutationHistory` for project/environment operational browsing with local-user authority, read-policy checks before and after storage access, policy updates and explicit close/cancellation checks. Agent authority cannot open this local-user service. The native screen is not wired yet. `swift test --package-path Packages/AgentDeskRuntime --filter NativeMutationHistoryTests` passed the read/revocation/close/agent-denial regression (`TestResults/p3-04/history-policy-tests.log`). The first compilation missed an AgentDeskSecurity import; fixed it, then the existing Jira edit regression also passed (`history-service-build-final.log`). Native and full integration checks remain due.

### Native mutation-history model

Added the Mac history model with bounded pagination, duplicate-load suppression, retry after failed open, and generation-based rejection of results arriving after close. Errors clear displayed rows rather than retaining potentially unauthorized history. The model compiles in the Mac app (`TestResults/p3-04/history-model-build.log`). Two native Mac tests passed using `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-04/history-model-tests.xcresult -only-testing:AgentDeskTests/MutationHistoryModelTests -parallel-testing-enabled NO test`: retry/error state and late failure after close. Native screen/navigation wiring remains incomplete.

### Native history sheet in progress

Added a top-aligned Mac sheet with project/environment labels, refresh, bounded load-more, empty/error/loading states, scrollable action/approval/run details, and explicit unresolved-versus-acknowledged outcome wording. It does not offer retry or imply that acknowledgment freezes remote state. The initial sheet build failed for a missing AgentDeskCore import (`TestResults/p3-04/history-view-build.log`); the import was added and validation rerun. Entry-point wiring and native UI behavior tests remain required; compilation alone does not complete the feature.

The corrected Mac sheet build passed (`TestResults/p3-04/history-view-build-final.log`).

### History navigation and locked-screen validation

Wired Mutation History into the run console using the selected environment. The factory resolves current project configuration and supplies a policy reload before and after every history read. The Mac application build passed (`TestResults/p3-04/history-navigation-build.log`).

The native UI test `NativeRunsUITests/testMutationHistoryOpensWithCompactHeaderAndCloses` failed during app launch after 61 seconds (`TestResults/p3-04/history-navigation-ui.xcresult` and matching log). Computer-use inspection reported that the Mac was locked and automatic unlock failed. The test process terminated before the attempted interrupt; no UI assertions or screenshot verification are claimed. This check requires the user to unlock the Mac. Non-UI policy validation can continue; the feature remains uncommitted and incomplete.

### Current-policy history regression

Extended the history-service regression to change policy from allow to deny between the two checks surrounding storage access. No history is returned. A current-configuration lookup failure also fails closed rather than using cached policy. `swift test --package-path Packages/AgentDeskRuntime --filter NativeMutationHistoryTests` passed (`TestResults/p3-04/history-policy-refresh.log`), followed by all 160 runtime host tests (`history-runtime-full.log`). These non-UI checks do not replace the blocked native navigation test.

### Shared history Simulator validation

The runtime suite passed 79 tests on iPhone 16 Pro / iOS 26.0 (`TestResults/p3-04/history-runtime-iphone.xcresult` and matching log), using the standard AgentDeskRuntime xcodebuild test command, primary Simulator UUID, `RuntimeIPhone` derived-data directory and disabled parallel testing. This tests the shared service, not a mobile history UI. Added native-interface documentation covering context, status interpretation, ordering and the incomplete visual acceptance. Documentation validation passed with 474 local links. Mac UI verification still requires an unlocked session.

### Locked-screen gate and resume

Added a Debug-only populated history fixture guarded by the existing UUID test-container and run-mode checks. It writes only synthetic unresolved/acknowledged attempts. The new UI test checks both labels and retains a screenshot. `xcodebuild ... build-for-testing` passed (`TestResults/p3-04/history-fixture-build.log`); this is compilation, not a UI pass. The iPhone companion build also passed (`TestResults/p3-04/history-app-iphone.log`).

Computer-use inspection again confirmed the Mac is locked. The same gate has persisted across multiple continuation turns while non-UI validation was completed. The history task remains uncommitted under the repository's native-validation/commit gate. Resume after manually unlocking the Mac: run both `NativeRunsUITests/testMutationHistoryOpensWithCompactHeaderAndCloses` and `NativeRunsUITests/testMutationHistoryShowsConfirmedAndUnresolvedAttempts` on macOS, inspect their screenshots, address any layout/behavior failures, review the focused diff, commit and push. Preserve the three unrelated Xcode/project handoff edits. No new repository or access reset is needed.

### Resumed native history acceptance — 2026-09-12

The Mac was unlocked. Both pending native UI tests passed using the same macOS AgentDesk scheme and NativeMac derived-data directory, with result bundle `TestResults/p3-04/history-ui-resumed.xcresult`. The command selected `NativeRunsUITests/testMutationHistoryOpensWithCompactHeaderAndCloses` and `NativeRunsUITests/testMutationHistoryShowsConfirmedAndUnresolvedAttempts`, with parallel testing disabled. Exported and visually inspected both screenshots: the header/actions remain visible, empty guidance fills the body, and acknowledged/unresolved rows fit without clipping. Export directory: `TestResults/p3-04/history-ui-resumed-shots`. Screenshots include unrelated desktop background and remain ignored test artifacts, not committed documentation.

This resolves the locked-screen validation gate for the history component. Existing evidence includes 50 persistence tests, 160 runtime host tests, 79 iPhone 16 Pro / iOS 26.0 runtime tests, two Mac model tests and both application builds. Native history provides observation only; remote reconciliation and remaining Jira mutation operations keep P3-04 incomplete.

### Text attachment draft in progress

Started scoped text-evidence attachments with deterministic multipart encoding, a bounded ASCII filename, matching filename/content scope, a 1 MiB text limit and a 70-character boundary. The exact multipart bytes are fingerprint-bound to the prepared attachment action; no local path is accepted. [Atlassian's attachment API](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-attachments/) confirms multipart uploads use the `file` field and the required X-Atlassian-Token header. Request dispatch, response validation, approval integration, binary attachments and native upload UI remain incomplete.

The plugin suite passed 74 tests (`TestResults/p3-04/text-attachment-draft.log`). Review then shortened the boundary and added a length assertion; the focused draft regression passed (`text-attachment-boundary.log`). Tests cover exact text preservation, deterministic encoding, changed filenames, header/path injection and foreign-run rejection. No external upload was attempted.

### Text attachment transport boundary

Added the fixed attachment POST request with the exact reviewed multipart body, selected-site and token write-scope checks, expiration validation and required upload headers. Successful receipts must contain exactly one numeric attachment ID with the expected filename and UTF-8 byte count; mismatched/malformed success responses remain uncertain. Explicit rejections are separate from uncertain server/network outcomes. `swift test --package-path Packages/AgentDeskPlugins` passed 75 tests (`TestResults/p3-04/text-attachment-write.log`). Dispatch through the authenticated session and reviewed runtime ledger remains to integrate; no upload occurred.

### Text attachment dispatch connected

Added exact-action session preparation/dispatch and the runtime approval-ledger wrapper for sanitized text attachments. Both filename and body are rechecked against current credential redaction; policy/evidence callbacks precede a persisted-grant recheck. Unknown transport outcomes do not retry. The attachment capability remains unadvertised while full attachment support is incomplete.

All 76 plugin tests passed (`TestResults/p3-04/attachment-session-tests.log`), including changed draft, credential echo, denied pre-dispatch evidence, logout during validation and successful upload receipt. Runtime dependency planning initially missed new files; `swift package --package-path Packages/AgentDeskRuntime clean` refreshed it. Seven existing Jira policy regressions then passed (`attachment-runtime-replanned.log`). Attachment-specific runtime approval/replay tests and native validation remain due; no external upload was performed.

### Reviewed text attachment backend acceptance — 2026-09-12

Added two runtime attachment regressions covering denied/unapproved dispatch, an exact approved upload, consumed-approval replay after reopening storage, unknown network outcomes retained as unresolved, and authority revocation during pre-dispatch validation. The session tests separately reject changed content, credential echoes and grants removed during validation. Multipart encoding and receipt validation use synthetic HTTP responses only.

Validation on Xcode 26.0, macOS 26.5.2 and the primary iPhone 16 Pro Simulator (iOS 26.0, `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`):

- `swift test --package-path Packages/AgentDeskRuntime`: 162 tests passed (`TestResults/p3-04/attachment-runtime-full.log`).
- Runtime package native macOS test: 162 tests passed (`attachment-runtime-mac.xcresult` and matching log).
- Runtime package native iPhone test: 81 tests passed (`attachment-runtime-iphone.xcresult` and matching log).
- Plugins package native iPhone test: 76 tests passed (`attachment-plugins-iphone.xcresult` and matching log). The earlier host plugin run also passed 76 tests.

Native package commands use `xcodebuild -scheme AgentDeskRuntime` or `AgentDeskPlugins`, `-destination 'platform=macOS'` or the primary iOS Simulator UUID, `-parallel-testing-enabled NO test`, and existing `TestResults/p3-04/RuntimeMac`, `RuntimeIPhone` or `PluginsIPhone` derived-data directories. Test names were corrected to describe attachments rather than comments before the iPhone runs. Existing SQLite fixture-cleanup warnings still occur in native runtime logs; test success is not a claim that those warnings were resolved.

This is a backend component of P3-04. Binary attachments, native upload review, attachment reconciliation, issue creation/deletion and full bug integration remain incomplete. Attachment capability discovery remains withheld; no live Jira upload or mobile upload UI is claimed.

Both ordinary application builds passed: `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build` (`attachment-app-mac.log`) and the same scheme targeting the primary iOS Simulator with `TestResults/p1-08b/FilteredIPhone` (`attachment-app-iphone.log`). Logs are under `TestResults/p3-04/`. Documentation integrity and diff whitespace checks passed.

### Attachment settings read in progress

Added an explicit `.attachmentSettings` read operation bound to connection configuration, scope, run and cloud identity under `attachmentsRead`. The authenticated session calls the fixed `/rest/api/3/attachment/meta` route with a 16 KiB response limit. Only typed enabled/size values, observation time and local scope escape decoding; unexpected remote strings are discarded. These settings describe site limits and do not confer upload permission or guarantee future server state. [Atlassian's attachment settings reference](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-attachments/#api-rest-api-3-attachment-meta-get) distinguishes site settings from issue-level attachment permissions.

The initial host plugin suite passed 78 tests (`TestResults/p3-04/attachment-settings-host.log`), covering exact routing, read grant/expiry, size limits, disabled attachments and malformed responses. Added exact settings-action/cloud binding checks and a runtime denial/approval/replay regression. The first Runtime build missed the new dependency source in its cached plan (`attachment-settings-policy.log`); `swift package --package-path Packages/AgentDeskRuntime clean` was run before retrying. Native validation and upload-flow integration remain pending.

### Attachment settings backend validation — 2026-09-12

After refreshing the Runtime build plan, both focused policy tests passed (`attachment-settings-policy-replanned.log`). Full native runs passed: 163 Runtime tests on macOS (`settings-runtime-mac.xcresult`), 82 Runtime tests on iPhone 16 Pro / iOS 26.0 (`settings-runtime-iphone.xcresult`), and 78 Plugins tests on that Simulator (`settings-plugins-iphone.xcresult`). Matching logs are under `TestResults/p3-04/`. Commands use the same package schemes, destinations, derived-data paths and disabled parallel testing documented in the text-attachment acceptance section above. macOS is 26.5.2 with Xcode 26.0. Existing SQLite fixture-cleanup warnings remain unresolved.

The native policy regression covers both issue reads and the new attachment-settings endpoint with denied/unapproved zero-request assertions and single-use approved dispatch. The Plugins tests additionally bind settings actions to the exact cloud and distinguish settings from attachment metadata. No live Jira request occurred. This completes the settings-read backend only; native upload preflight and binary evidence remain part of unfinished P3-04.

Both normal application builds passed (`settings-app-mac.log`, `settings-app-iphone.log`), using the AgentDesk project/scheme and native build commands recorded above. Documentation integrity and whitespace checks passed. No new UI surface was added by this backend change.

### Mandatory attachment preflight in progress

Text attachment dispatch now requires a fresh attachment-settings observation obtained through a separate Runtime read-policy session. A denied or non-executed read cannot authorize the upload. The session checks exact context/cloud identity, enabled state, UTF-8 file size and observation time before the final authority/grant checks. Observations predating this dispatch attempt or ahead of the dispatch clock fail closed. These checks do not promise atomic server state: Jira can still change settings or issue permissions before the POST.

The two focused runtime attachment tests passed (`TestResults/p3-04/attachment-preflight-policy.log`), now exercising the settings GET before the approved POST. All 78 host Plugins tests passed (`attachment-preflight-plugins.log`); the session regression additionally checks disabled uploads, an undersized limit, a foreign site, stale and future observations cause zero upload requests. Full native validation is pending; the component remains uncommitted until that gate is satisfied.

### Attachment preflight native validation — 2026-09-12

Native suites passed: 163 Runtime tests on macOS (`preflight-runtime-mac.xcresult`), 82 Runtime tests on iPhone 16 Pro / iOS 26.0 (`preflight-runtime-iphone.xcresult`), and 78 Plugins tests on the same Simulator (`preflight-plugins-iphone.xcresult`). Matching logs are under `TestResults/p3-04/`. Commands use the package schemes, primary Simulator UUID, existing RuntimeMac/RuntimeIPhone/PluginsIPhone derived-data paths and disabled parallel testing recorded above. Host toolchain: Xcode 26.0 on macOS 26.5.2. Existing SQLite fixture-cleanup warnings are still present.

This validates mandatory preflight for the current text upload path, not binary-file upload or a native upload UI. The server remains authoritative for actual issue-level permissions and settings changes after observation. Pre-dispatch failures conservatively leave the already-started mutation record unresolved; they never trigger an automatic upload retry.

Normal Mac and iPhone app builds both passed (`preflight-app-mac.log`, `preflight-app-iphone.log`), using the AgentDesk scheme and native destinations/derived-data paths recorded above. Documentation and diff checks passed. The preflight component is ready for its focused commit; P3-04 remains open.
