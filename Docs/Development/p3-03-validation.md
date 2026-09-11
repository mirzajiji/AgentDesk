# P3-03 — Jira authentication and read capabilities

Status: in progress, uncommitted. Deployment preference (Cloud/Data Center/both) requested. With no response, implementation proceeds with Cloud first and OAuth 2.0. The confidential code-exchange deployment remains unresolved; no interactive sign-in is exposed yet.

Official references consulted on 2026-09-11:

- [Jira Cloud authentication](https://developer.atlassian.com/cloud/jira/platform/basic-auth-for-rest-apis/) documents email/API-token basic authentication and recommends distributable OAuth integrations for apps. Its restrictions on collecting customer tokens must inform the product login design.
- [Current-user API](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-myself/) provides account-validation behavior.

The initial internal HTTP transport uses an ephemeral session without shared cookies, credential storage or URL cache; validates same-origin requests; rejects redirects; and bounds response size. It compiles and the existing nineteen plugin tests pass (`TestResults/p3-03/transport-compile.log`). These are not transport integration tests. Explicit early-response cleanup, transport fixtures, authentication, capability discovery, read operations, native validation and documentation remain incomplete. No live Jira request or credential access has occurred.

HTTP boundary tests now reject foreign origins, sibling base paths, traversal paths and sends after close. Each response task is explicitly cancelled on exit, including oversized/redirect/error paths. Synthetic URLProtocol responses exercise exact-size success, HTTP 401 preservation, advertised and streamed over-limit bodies, and rejection of a 302 response. All 23 package tests pass (`TestResults/p3-03/http-responses.log`). This does not yet verify an actual redirect delegate callback or cancellation while a response is stalled; those remain transport validation work.

Stalled-response cancellation now confirms transport start and observes stopLoading after cancellation (`http-cancellation-observed.log`, 24 tests passed). Cloud account decoding requires an active identity and bounded required fields, and maps HTTP failure statuses to safe categories without including response bodies. Synthetic account/status tests bring the package suite to 26 passing tests (`account.log`). Authentication is not implemented by parsing a profile; no real login or company request is claimed.

[Atlassian OAuth documentation](https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/) requires client_secret for code exchange and refresh, plus an unguessable state and exact registered callback. The initial OAuth-attempt actor builds authorization URLs and validates scoped, expiring, single-use callbacks; authorization codes use SecretValue. No client secret is embedded. A distributable confidential exchange service or another explicitly supported login architecture remains unresolved, The callback tests described below validate the local attempt boundary.

OAuth callback tests now cover foreign connection rejection, required state, duplicate query rejection, secret-safe code handling, replay and expiry. All 28 package tests pass (`oauth-tests.log`). Expired or backward-clock attempts are now permanently invalidated; the existing suite also passes after that change (`oauth-clock.log`), and a dedicated backward-clock regression subsequently passed (`oauth-clock-regression.log`, 29 tests).

## Configured Jira Cloud site selection

Added accessible-resource response selection for the exact configured HTTPS site. Ambiguous matching resources, malformed IDs, credential-bearing URLs and unexpected paths fail closed. Bearer API destinations are constructed exclusively on the fixed Atlassian gateway with a validated cloud UUID; server-returned site URLs are never token destinations. This follows [Atlassian's OAuth resource routing](https://developer.atlassian.com/cloud/jira/platform/oauth-2-3lo-apps/).

`swift test --package-path Packages/AgentDeskPlugins` passed 34 tests, zero failures, on macOS 26.5.2 with Swift 6.2 (`TestResults/p3-03/resources.log`). Added tests cover exact site selection among multiple tenants, missing authorization, duplicate resources, unsafe URLs and path-injection IDs. The preceding credential validation run also passed all 32 tests (`vault-validation.log`). `git diff --check` passed. These are synthetic local tests; they do not establish live Jira authentication, native UI integration or iPhone coverage. P3-03 remains in progress and uncommitted.

## Authenticated profile probe

Added the internal `JiraAccountRequest` probe, using the validated cloud resource and the fixed gateway `/rest/api/3/myself` endpoint. It checks expiry at the supplied clock time and requires the configured classic `read:jira-user` scope in both the token grant and site resource. It sends only the access token as a bearer header, with no body or refresh token. OAuth scopes do not replace the host policy boundary; the later adapter integration below now invokes this probe from the connection lifecycle. Endpoint reference: [Get current user](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-myself/).

`swift test --package-path Packages/AgentDeskPlugins` passed 37 tests, zero failures (`TestResults/p3-03/account-request-integrated.log`). New tests cover exact routing/header contents, expiry boundary and invalid clock, missing token/site scopes, and a profile request through the real isolated transport with a synthetic URLProtocol response. This is HTTP interception inside the test process, not a live Jira server or completed OAuth login. `git diff --check` passed. P3-03 remains incomplete; no feature commit or native coverage is claimed for these additions.

## Connection lifecycle integration

The internal Cloud adapter now restores a credential bundle from the exact configuration's scoped SecretStore, fetches accessible resources from the fixed Atlassian endpoint, selects the configured site and validates the active account before returning a session. Missing/expired grants map to the existing authentication-expired lifecycle state. Failed and cancelled connection attempts close partial transports. The session currently advertises no issue capabilities because issue execution is not implemented yet. Interactive sign-in, rotating refresh, issue reads and native setup remain pending; this does not complete P3-03.

`swift test --package-path Packages/AgentDeskPlugins` passed 38 tests, zero failures (`TestResults/p3-03/adapter-lifecycle.log`). The new integration test drives the existing lifecycle through missing credentials, scoped grant restoration, synthetic HTTP site/account validation, disconnect, deletion and rejected reconnect after logout. The fake URLProtocol checks bearer authorization and exact endpoint paths. No live account or secret was accessed. `git diff --check` passed.

## Internal issue read implementation

Added a GET issue transport operation with a fixed field selection, bounded path identifiers, expiry checks and required token/site read scopes. The operation rejects mismatched project/environment/redaction contexts before network access. Responses pass through the centralized JSON redactor before becoming evidence; exact JSON structure, including ADF description content, is preserved. Requested and returned identifiers remain distinct because Jira can resolve a moved issue without an HTTP redirect. The timestamp currently records the supplied request observation time. Runtime policy integration is still required before exposing this operation as an advertised capability.

Reference: [Jira v3 Get issue](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issues/). `swift test --package-path Packages/AgentDeskPlugins` passed 40 tests, zero failures (`TestResults/p3-03/issue-read.log`). New synthetic transport tests cover moved keys, field selection, credential-field redaction, scope rejection, missing grants and path/query/fragment/header injection identifiers. `git diff --check` passed. No live Jira read, native integration, feature completion or commit is claimed.

## Native checkpoint

The current 40-test plugin suite passed independently under native macOS XCTest and on the local iPhone 16 Pro Simulator (iOS 26.0, UUID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`), zero failures. Xcode 26.0 on macOS 26.5.2. These are package test runs, not app UI integration or live Jira acceptance.

Commands run sequentially from `Packages/AgentDeskPlugins`:

```sh
xcodebuild -scheme AgentDeskPlugins -destination 'platform=macOS' -derivedDataPath ../../TestResults/p3-03/PluginMac -resultBundlePath ../../TestResults/p3-03/plugin-mac.xcresult -parallel-testing-enabled NO test
xcodebuild -scheme AgentDeskPlugins -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-03/PluginIPhone -resultBundlePath ../../TestResults/p3-03/plugin-iphone.xcresult -parallel-testing-enabled NO test
```

Logs are `plugin-mac.log` and `plugin-iphone.log` beside the bundles. Public OAuth client ID and registered callback details have been requested; no client secret was requested in chat. P3-03 is still in progress, with no feature commit yet.

## Comment pages

Added bounded comment-page requests with a fixed route and created-order paging. Responses must match the requested offset, advance by actual returned count, contain unique valid comment IDs and have consistent totals. Empty unfinished pages fail instead of creating a pagination loop. Page JSON passes through centralized redaction and retains its project/environment/run context. Each page still requires runtime policy integration before the capability can be exposed. Reference: [Jira Get comments](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-comments/).

`swift test --package-path Packages/AgentDeskPlugins` passed 42 tests, zero failures (`TestResults/p3-03/comments.log`). New tests cover first/final/empty pages, wrong offsets, duplicate IDs, inconsistent totals, stalled pagination, unsafe IDs, bounded query parameters and sensitive-field redaction. `git diff --check` passed. The previous native checkpoint covered 40 tests before this addition; these new comment tests have not yet run in native Xcode/Simulator. No feature completion or commit is claimed.

## Attachment metadata

Added a fixed-gateway attachment metadata read with numeric identifier validation, exact returned-ID checks, nonnegative size and bounded filename/MIME metadata. Filenames and server-returned content URLs remain redacted evidence only; neither controls a filesystem write or bearer request destination. Scope validation precedes the request. Actual content downloading and runtime policy integration remain pending. Reference: [Jira attachment APIs](https://developer.atlassian.com/cloud/jira/platform/rest/v3/api-group-issue-attachments/).

`swift test --package-path Packages/AgentDeskPlugins` passed 44 tests, zero failures (`TestResults/p3-03/attachment-metadata.log`). New tests cover exact metadata routing, unsafe request IDs, returned-ID mismatch, negative sizes, malformed names and sensitive-field redaction. `git diff --check` passed. Native checkpoint coverage remains the earlier 40-test run, not these additions. P3-03 remains uncommitted and incomplete.

## Bounded attachment content

Added an internal attachment content downloader using the fixed gateway with `redirect=false`. Metadata now carries cloud identity; cross-site metadata fails before requests. Download size is capped before sending and while streaming, and the completed body must exactly match the metadata size with HTTP 200. Partial or changed-size content is rejected. Returned bytes use a non-Codable private wrapper with redacted descriptions/reflection and explicit scoped access. No bytes are persisted or displayed; extraction/redaction and runtime authorization still need integration. The transport now permits a smaller per-request response ceiling within its configured maximum.

`swift test --package-path Packages/AgentDeskPlugins` passed 46 tests, zero failures (`TestResults/p3-03/attachment-download-bounded.log`). Tests cover exact content routing, disabled redirects, cross-site metadata, oversized declarations, partial responses, mismatched lengths and private byte handling. Existing streamed response limits also remain green; a dedicated lowered per-request ceiling assertion remains to add. `git diff --check` passed. Native validation remains the earlier 40-test checkpoint. P3-03 is not complete or committed.

## Read-operation native checkpoint

The dedicated per-request transport test now confirms smaller streamed limits, invalid limit rejection, exact-limit success and unaffected subsequent requests. `request-limits.log` records 47 passing SwiftPM tests.

All 47 plugin tests also passed with zero failures on native macOS and iPhone 16 Pro Simulator iOS 26.0. Commands are the native checkpoint commands above, with result paths `reads-mac.xcresult` and `reads-iphone.xcresult`; logs are `reads-mac.log` and `reads-iphone.log`. These runs cover the current issue, comment, attachment metadata/download and transport test additions. They remain synthetic package tests rather than live Jira or app UI acceptance.

`python3 Scripts/validate-documentation.py` passed (159 sections, 100 Markdown files, 467 local links); `git diff --check` passed. Runtime policy binding, interactive OAuth and refresh, native setup and complete P3-03 acceptance remain unfinished. No feature commit yet.

## Exact read invocation identities

Added validated `JiraReadOperation` values for issue reads, comment pages, attachment metadata and attachment content. Preparation binds cloud identity, target identifier, operation kind, page offset/limit, expected attachment size and byte ceiling into the existing configuration/permission/run-bound action fingerprints. Preparation itself grants no transport access. This supplies the concrete identity needed by runtime approval integration; the executor is still pending.

`swift test --package-path Packages/AgentDeskPlugins` passed 48 tests, zero failures (`TestResults/p3-03/read-operation.log`). New regression assertions prove stable identity for an identical invocation and changed identity for another issue/site/page/limit/metadata-vs-content/expected-size/byte ceiling, with malformed invocations rejected. Native evidence remains the preceding 47-test checkpoint. No completed-feature commit yet.

## Authenticated session executor

The restored Cloud session now prepares concrete read identities and dispatches issue/comment/attachment operations after checking the exact prepared action, run context and current stored grant. Deleted or replaced credentials invalidate execution; closing the session closes its transport. Attachment content checks the fresh metadata size against the prepared size. Public execution is explicitly a trusted-runtime transport interface, not an authorization grant; the runtime PolicyGate wrapper remains required, and capabilities remain unadvertised until that integration is complete.

`swift test --package-path Packages/AgentDeskPlugins` passed 48 tests, zero failures (`TestResults/p3-03/session-executor-tested.log`). The expanded adapter integration test now restores a grant, reads a synthetic issue through the session, rejects a substituted issue target and rejects execution after logout. Existing checks remain green. `git diff --check` passed. Native coverage remains the preceding 47-test checkpoint. P3-03 stays incomplete and uncommitted.

## Runtime policy dispatch

Added the runtime `PluginPolicySession.executeJira` entry point. It dispatches the concrete authenticated-session executor only inside the existing exact-action PolicyGate closure, preserving configuration/policy revalidation and authority-generation checks. The caller supplies the reviewed operation and scoped redactor; the transport session independently checks action identity and current credentials.

`swift test --package-path Packages/AgentDeskRuntime --filter JiraPolicyReadTests` passed one integration test (`runtime-jira-gate.log`). The test drives the actual runtime gate and Jira HTTP transport with synthetic responses: denied and unapproved reads cause zero HTTP requests; approved execution causes exactly one; reusing the consumed approval causes no additional request. No live Jira access occurred. Full runtime regression results follow below. Native application setup, interactive OAuth/refresh, capability exposure and full acceptance remain unfinished.

`swift test --package-path Packages/AgentDeskRuntime` passed all 151 tests, zero failures (`runtime-integrated.log`). `git diff --check` passed. This does not replace native application/Simulator validation of the runtime integration. P3-03 remains uncommitted and incomplete.

## Active credential echo redaction

The authenticated executor now extends the supplied scoped redaction policy with its active access/refresh values before reading response evidence. This masks tokens echoed inside ordinary summary/body strings, not just values under sensitive field names. The central redactor extension preserves existing known values and custom field rules, rejects foreign contexts and retains existing count/size bounds. It returns a copy without mutating the caller's policy.

`swift test --package-path Packages/AgentDeskSecurity` passed 25 tests (`security-token-redaction.log`); `swift test --package-path Packages/AgentDeskPlugins` passed 48 tests (`jira-token-redaction.log`), zero failures. The new security test covers preservation, additional masking and context mismatch; the session integration fixture now echoes its synthetic access token in an issue summary and verifies redaction. `git diff --check` passed. Native checks for these latest changes are pending; this is part of unfinished P3-03, not a completed feature commit.

## Signed app integration checkpoint

The signed native Mac app passed all 16 selected tests from `JiraPolicyReadTests`, `PluginPolicySessionTests` and `ContentRedactorTests`, zero failures (`runtime-native-mac.xcresult` / `.log`). This includes actual runtime gate-to-Jira-transport dispatch with synthetic HTTP and active credential echo redaction. Command:

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-03/runtime-native-mac.xcresult -only-testing:AgentDeskTests/JiraPolicyReadTests -only-testing:AgentDeskTests/PluginPolicySessionTests -only-testing:AgentDeskTests/ContentRedactorTests -parallel-testing-enabled NO test
```

Review follow-up: attachment content currently validates its stored grant before metadata retrieval; it should recheck the grant between metadata retrieval and the content request as well. This remains an implementation item, not a verified fix.

The matching native iPhone 16 Pro Simulator run on iOS 26.0 passed the same 16 tests, zero failures (`runtime-native-iphone.xcresult` / `.log`). It used the same selectors with destination `platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`, derived data `TestResults/p1-08b/FilteredIPhone` and the iPhone result path. Both applications built successfully for these test runs. This establishes native integration coverage, not a working Jira setup UI or live OAuth authentication. P3-03 remains in progress.

## Attachment grant recheck

Resolved the review follow-up: the session now reloads and validates its exact grant again after metadata retrieval and before downloading attachment content. The shared check also verifies cancellation and closed-session state around the credential-store await.

`swift test --package-path Packages/AgentDeskPlugins` passed 49 tests, zero failures (`attachment-grant.log`). The new integration test uses a scoped secret-store fixture that returns the grant on the first read and removes it on the next. The HTTP fixture confirms that metadata was fetched and no content request followed when the second credential check failed. This is a deterministic missing-grant regression, not a live OAuth revocation test. `git diff --check` passed. Native coverage for this addition remains pending; P3-03 is still unfinished.

## Read capability discovery and response ceilings

With concrete read implementations and runtime dispatch present, authenticated sessions now advertise issue/comment/attachment reads when both the token and selected-site grants include `read:jira-work`. No mutation capability is advertised. Discovery describes supported operations and does not bypass runtime permissions or Jira's per-resource authorization.

The production adapter now supports the documented 8 MiB maximum attachment ceiling; discovery/account/issue/comment/metadata requests impose a separate 256 KiB streaming ceiling. This corrects the earlier mismatch between the allowed attachment request limit and the adapter's 2 MiB transport default.

`swift test --package-path Packages/AgentDeskPlugins` passed 50 tests, zero failures (`read-capabilities.log`). Discovery tests cover both grants, either missing grant and write-only grants; the integrated lifecycle checks the resulting read capability set. Existing request-limit and download tests remain green. `git diff --check` passed. Native reruns, OAuth login/refresh, app setup and complete P3-03 acceptance remain outstanding.

## Network diagnostic boundary and native reads

Native Mac XCTest passed all 50 plugin tests before the network-error addition (`capabilities-mac.xcresult` / `.log`). The transport now maps unrecognized network failures to a fixed `networkUnavailable` category, retaining explicit boundary errors and cancellation without propagating raw NSError diagnostics. A synthetic failure containing a private diagnostic verifies that it does not escape.

The updated suite passed 51 SwiftPM tests on Mac (`network-errors.log`) and all 51 tests on the iPhone 16 Pro Simulator iOS 26.0 (`network-iphone.xcresult` / `.log`), zero failures. Native package commands follow the earlier checkpoint, with those result paths. `git diff --check` passed. The latest network-error addition has SwiftPM Mac and native iPhone coverage; the preceding native Mac checkpoint contains 50 tests. OAuth login/refresh and final P3-03 acceptance remain unfinished; no commit yet.

## Backend acceptance and task decomposition

The chronology above records development of the original combined task; earlier incomplete/uncommitted statements describe those checkpoints. P3-03 is now split into P3-03a (read backend and authentication primitives) and P3-03b (interactive OAuth lifecycle). See [P3-03a acceptance](p3-03a-validation.md) for the committed scope and explicit remaining requirements. Final native Mac package validation passed 51 tests (`backend-final-mac.xcresult`); final runtime regression passed 151 tests (`backend-final-runtime.log`). Interactive OAuth and native setup remain unfinished and are not covered by the backend completion claim.
