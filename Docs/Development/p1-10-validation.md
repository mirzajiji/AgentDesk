# P1-10 policy and durable approvals validation

Date: 2026-09-10. Starting commit `6eaf67c`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, MacBook Pro arm64, macOS 26.5.2 (25F84). Primary Simulator: AgentDesk iPhone 16 Pro, iOS 26.0 (23A343), ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. The full device/OS matrix remains deferred by user instruction.

## Implemented and exercised

Core now validates versioned human-readable policy documents, immutable prepared-action identities/digests and approval records. Security evaluates allow/approval/deny deterministically across workspace, project and environment restrictions, authenticated-authority grants, expiry/revocation, agent/mobile restrictions, workspace lock and production safety. Missing rules deny. Runtime's internal gate prepares review, rechecks policy/authority at dispatch and consumes approvals before invoking an exact prepared effect. Persistence schema 4 adds scope-bound approval snapshots and ordered audit events to the existing operational database.

Approval binds the exact workspace/project/environment/run/agent, action nonce/classification, resolved-resource fingerprint, prepared nonsecret payload fingerprint, policy snapshot and requester revision. Reviewer identity/revision is recorded separately and rechecked. Preparation is idempotent and cannot extend an existing approval's expiry. Modified payloads require a new action; modify-and-approve preserves the old action and commits its modified status plus a newly approved replacement atomically. Human rejection remains possible after requester revocation. Agents cannot approve themselves.

The acceptance scenario uses a real temporary synthetic file: an unapproved write is rejected; human review permits the exact prepared write once; its bytes match the approved payload; a second dispatch is rejected. Two concurrent gates and two independent SQLite connections cannot consume the same grant twice. Deliberately failed effects leave the grant consumed, so an uncertain external effect is not silently retried. Dry run, denial and predispatch cancellation perform no effect and create no approval rows.

This is an internal authorization foundation. It does not implement Jira/database integrations merely because their risk categories can be classified. It does not yet expose native approval UI, LAN commands, authenticated device pairing, arbitrary XPC execution or a policy editor. The caller must authenticate principals, resolve resources and run membership, freeze the real effect, use nonsecret metadata/references and show the redacted human-readable proposal before collecting review. The later coordinator joins policy with actual provider runs, lifecycle state and result persistence. See [policy contract](../Architecture/permissions.md) and [storage contract](../Architecture/persistence.md).

## Accepted tests

- **70 Core tests:** includes exact identity/payload fingerprint changes, JSON round-trip, future/duplicate/foreign policy rejection and invalid/unreviewed approval records.
- **12 Security tests:** includes all 27 allow/approval/deny precedence combinations, missing/expired/revoked/foreign/ungranted authority, mobile/agent escalation denials, production/locked contexts and safe preset defaults.
- **25 Persistence tests:** includes approval restart/replay, exact action/requester/policy binding, all three scope dimensions, stale sequences, idempotency, expiry/rejection/clock regression, concurrent consumption, atomic replacement rollback after an injected audit failure, cancellation/corruption and version-3 migration retaining run rows. Existing run/progress tests now expect schema 4.
- **64 Runtime tests:** includes reviewed file effects, dry-run/cancellation/denial, changed/expired payloads, requester/reviewer revocation, restored reviewer revisions, changed policy revisions, agent self-approval denial, human rejection after revocation, modified proposals and failed/concurrent dispatch. Existing provider/process/lifecycle tests remain passing.
- **183 native Mac unit/integration tests plus one Settings UI test pass.** The signed helper's real health/disconnect/reconnect flow remains working without signing out the developer.
- **141 iPhone unit/integration tests pass** on the primary local Simulator. Policy/gate/storage code is shared and does not make the phone an execution authority.

Initial compilation required explicit propagation of the throwing clock read; accepted suites ran after that correction. All four package suites and both native suites pass. No external effect, live company service, new Codex model call, login/logout mutation or secret content is required by these tests. Temporary data, UUID principals, fixtures and injected database failures are synthetic.

```sh
swift test --package-path Packages/AgentDeskCore
swift test --package-path Packages/AgentDeskSecurity
swift test --package-path Packages/AgentDeskPersistence
swift test --package-path Packages/AgentDeskRuntime
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-10/mac-first.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -only-testing:AgentDeskUITests/AgentDeskUITests/testCodexSettingsHealthDisconnectAndReconnectPersistWithoutSigningOut \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-08b/FilteredIPhone \
  -resultBundlePath TestResults/p1-10/iphone-first.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
python3 Scripts/validate-documentation.py
git diff --check
```

Accepted logs and native result bundles are under ignored `TestResults/p1-10/`: `AgentDeskCore-first.log`, `AgentDeskSecurity-first.log`, `AgentDeskPersistence-first.log`, `Runtime-first.log`, `mac-first.log/.xcresult` and `iphone-first.log/.xcresult`.

## Storage and integration limits

Schema 4 adds approval and audit tables transactionally and does not rewrite runs/progress. Older schema-3 binaries refuse an upgraded database; rollback must not reset or downgrade it. The ledger gives at most one authorized dispatch attempt. A consumed record is not evidence that an external effect succeeded, and a crash between consumption and execution may spend an unused grant. Recovery and side-effect-specific idempotency belong to the coordinator/adapters.

Authority descriptors are trusted in-memory host inputs and are never decoded from action requests. Pairing/credential validation and persistent authority configuration are future integration gates. Policy documents have validated JSON codecs, but filesystem policy management/editor integration is still part of effective configuration. Raw prepared resource paths and payloads are not stored in the approval ledger; fingerprints cannot substitute for a human-readable review screen. Existing app forms are not claimed to be routed through the new gate yet.


The normal signed Mac build also passes (`normal-mac-build.log`, using `TestResults/p1-08b/NormalMac`). System-service `codesign --verify --strict --verbose=2` validates the app and embedded helper. No signing/provisioning/entitlement or XPC-interface changes belong to this task. The iPhone artifact contains no XPC service. The effective Xcode graph matches HEAD after its already documented normalization; unrelated formatting, personal scheme UI metadata and historical handoff changes remain unstaged. Documentation integrity/coverage/link/ignore checks and diff review pass; no generated output, credentials or company data is included.
