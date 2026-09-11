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
