# P3-03a — Jira read backend and authentication primitives

Status: acceptance complete for the backend scope below. Interactive OAuth is P3-03b; native connection setup remains P3-05. Neither is claimed complete.

## Implemented boundary

- Restore an existing project/environment/connection-bound OAuth bundle through SecretStore; validate the configured Cloud site and active account before returning a session. Discovery requires both site and token read grants.
- Read issues, bounded comment pages, attachment metadata and bounded attachment content through fixed Atlassian gateway routes. Preserve JSON/ADF as scoped, centrally redacted evidence. Downloaded binary bytes remain private and unpersisted until an explicit consumer processes them.
- Prepare exact operation identities and dispatch through the runtime policy gate. Denied/unapproved operations do not reach HTTP; consumed approvals cannot replay. Bind site, target, page, configuration, permissions, run and attachment size/limits.
- Recheck credentials before execution and between attachment metadata/content requests; reject deleted/replaced grants. Close partial transports on errors and cancellation. Reject redirects, cross-origin paths, malformed paging/identity/size responses and oversized streams.
- Mask known credentials in echoed response text as well as sensitive field names. Network errors expose fixed categories, not underlying diagnostic text.
- Provide tested token parsing/storage and single-use scoped OAuth callback primitives for the next task. No confidential client secret is embedded.

## Evidence

All fixtures are synthetic; no live Jira account was accessed.

| Check | Result and record |
| --- | --- |
| Plugin package, SwiftPM Mac | 51 tests passed, zero failures; `TestResults/p3-03/network-errors.log` |
| Native Mac plugin XCTest | 51 tests passed, zero failures; `backend-final-mac.xcresult` / `.log` |
| Native iPhone plugin XCTest | 51 tests passed, zero failures; `network-iphone.xcresult` / `.log` |
| Security SwiftPM | 25 tests passed, zero failures; `security-token-redaction.log` |
| Signed Mac app integration | 16 selected policy/redaction tests passed; `runtime-native-mac.xcresult` |
| Native iPhone app integration | Same 16 tests passed; `runtime-native-iphone.xcresult` |

Native app integration preceded the final attachment recheck/capability/network refinements; the later native package runs cover those refinements. Device: iPhone 16 Pro Simulator, iOS 26.0, UUID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. Host: macOS 26.5.2; Xcode 26.0 / Swift 6.2. Exact commands and incremental results are retained in the [development validation record](p3-03-validation.md).

## Remaining original scope

P3-03b must implement interactive sign-in, confidential code exchange, refresh rotation, logout/reauthentication coordination and its tests. Public registration details were requested; a production exchange deployment is not configured. P3-05 must expose scoped configuration, permissions, login, diagnostics and reads through native setup. No live integration acceptance, physical display matrix, broader iPhone matrix or full Phase 3 completion is claimed. Jira mutations remain P3-04.

Final affected runtime regression: `swift test --package-path Packages/AgentDeskRuntime` passed all 151 tests, zero failures (`backend-final-runtime.log`). Documentation validator passed: 159 sections, 101 Markdown files and 469 local links. `git diff --check` passed.
