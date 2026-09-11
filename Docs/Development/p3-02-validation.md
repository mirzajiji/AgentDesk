# P3-02 — Plugin capability policy and exact approvals

Implemented and validated, 2026-09-11.

## Implemented boundary

PluginPermissions binds a versioned document to one connection, project and environment. Missing rules deny access, duplicate rules are rejected, and per-capability restrictions can only narrow the existing policy. Workspace/project rules, production restrictions and workspace locks remain intact.

PreparedPluginAction fingerprints the exact configuration contents/revision, permission contents/revision, capability and resolved resource, plus the sanitized payload fingerprint. Changing an endpoint even without changing its revision changes the binding. Preparing an identity does not authorize an effect.

The internal Runtime PluginPolicySession delegates preparation, review and execution to the existing PolicyGate and durable ApprovalStore. It rejects mismatched permission documents, rechecks the current action and base-policy fingerprint, and detects authority changes during asynchronous final validation. Direct paired-device plugin requests are denied, including otherwise-allowed reads. Trusted host adapters must supply current context and exact prepared effects; this interface is not decoded from mobile or agent requests.

Approvals are consumed before effects. Failed dispatch and revocation during the final check leave them spent. No automatic fallback or retry restores authority. Existing PolicyGate regressions cover expiry, changed payload, cancellation and concurrent consumption. Live Jira adapters and native connection UI remain P3-03–P3-05; this task does not claim an external service operation.

## Results

Mac: arm64 macOS 26.5.2 (25F84), Xcode 26.0 (17A324). iPhone: iPhone 16 Pro / iOS 26.0 (23A343), simulator C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE.

| Evidence in ignored TestResults/p3-02 | Result |
| --- | --- |
| plugins-final.log | 19 package tests passed, including nine policy combinations and exact action binding |
| runtime-full.log | 150 Runtime tests passed before the final mobile restriction |
| mac-linked.xcresult | 520 native Mac tests passed |
| iphone.xcresult | 339 native iPhone tests passed |
| mobile-read-denial.log | Two integrated session tests passed with the final mobile restriction |
| mac-final.xcresult | Focused native session tests passed after the final restriction |
| iphone-final.xcresult | Two final focused iPhone session tests passed |

Session scenarios cover allow/deny/approval, exact execution, replay rejection, failed effects, changed base policy, revoked authority while the final validation is paused, and paired-device denial. Tests use synthetic local effects and isolated temporary databases. SQLite temporary-fixture teardown warnings occur in broader suites; this task does not claim to fix them or infer production corruption. Physical displays and broader device/runtime matrices remain deferred to final product acceptance.

Earlier failures are preserved: session.log initially used an invalid operational database filename, corrected to operations.sqlite; mac.xcresult failed linking the new plugin types until the native test target gained its explicit AgentDeskPlugins dependency. The user’s unrelated Xcode normalization remains unstaged; `/private/tmp/agentdesk-plugin-project.patch` contains only this task’s native project dependency changes for selective staging.

## Commands

```sh
swift test --package-path Packages/AgentDeskPlugins
swift test --package-path Packages/AgentDeskRuntime
swift test --package-path Packages/AgentDeskRuntime --filter PluginPolicySessionTests
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-02/mac-linked.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p3-02/iphone.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```

Final native rechecks use the same platform commands with `-only-testing:AgentDeskTests/PluginPolicySessionTests` and fresh mac-final/iphone-final result paths. Documentation integrity, coverage, links and ignore-rule checks pass.
