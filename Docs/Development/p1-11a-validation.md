# P1-11a policy-gated run coordination

Date: 2026-09-10. Starting commit `0315c62`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, macOS 26.5.2 (25F84), arm64. Primary native iPhone destination: **AgentDesk iPhone 16 Pro**, **iOS 26.0 (23A343)**, ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. The broader device/minimum-runtime matrix remains deferred by the user's development-device instruction.

## Implemented

The internal coordinator joins frozen configuration/instructions, physical repository identity, deterministic policy and one-time approvals, provider events, open-ended progress, redacted evidence and terminal lifecycle state. A project lease excludes concurrent local owners across environments. Preparation never dispatches Codex; start requires the exact prepared capability and current authorization. A structured watchdog covers quiet-provider timeout/revocation, and terminal cleanup persists independently of consumer cancellation. Keyset-paged startup recovery marks interrupted runs explicitly failed without rerunning historical actions.

The [execution contract](../Architecture/execution.md) documents limits, cancellation/lifetime responsibilities, evidence semantics and recovery boundaries. This task implements the shared coordinator; the signed Mac execution transport, native run service and run UI remain separate tasks. Existing real Mac provider/Git adapters implement the resource identity contract. No entitlement, helper authority, cloud/API credential or production-company data changes are included.

## Validation results

- **97 Core tests pass**, including the updated complete transition matrix permitting approval wait before launch.
- **39 Persistence tests pass**, including scoped recovery pagination/binding queries, invalid limits, missing/foreign records and inconsistent stored environment rejection. Schema remains version 5.
- **96 Runtime tests pass**, including 14 new coordinator/boundary tests. These exercise successful evidence/progress persistence/reopening, sanitized dispatch, final interpretation provenance, activity limits, exact approval consumption/replay, denied requests before secret resolution, declined/stale approvals, discard, foreign instructions/repositories, final capture failure, malformed/late events and late transport errors, missing completion/activity completion, schema/output bounds, quiet cancellation/timeout/revocation, concurrent shutdown during preparation/execution, lease contention/replacement/link attacks, 260 interrupted runs across pages, foreign/terminal preservation and unconfirmed terminal persistence failure.
- **267 affected native Mac unit/integration tests pass**, including the new coordinator and recovery tests inside the sandboxed app. The two unchanged Keychain tests are excluded as described below; no interactive UI acceptance is counted.
- **215 native iPhone unit/integration tests pass** on the primary iPhone 16 Pro Simulator. Shared coordinator logic runs there with fake providers; actual Codex/Git subprocess execution remains Mac-only.
- The **normal signed Mac build passes**. App and helper signatures verify; the main app retains App Sandbox and user-selected read-only files, while the previously approved helper retains its existing unsandboxed configuration.
- Documentation source integrity, all 159 sections and ownership/coverage, local links, ignore rules and whitespace checks pass. The personal GitHub remote and effective personal author/committer are verified before staging/push.

## Attempts and unavailable checks

Initial compilation corrected a missing throwing-call marker and removed an unnecessary async autoclosure. The first focused eight tests passed, followed by all 14 coordinator tests. The first native Mac build required an explicit `Synchronization` import in the boundary test file; SwiftPM had compiled it through its existing module graph. That failed native attempt executed no product tests. The explicit import is present for the retry.

The unchanged two Keychain integration tests and interactive UI suite are excluded from this backend task's native Mac batch because P1-12c established unavailable interactive access (`errSecInteractionNotAllowed` and app activation timeout). Their earlier passes are not counted here. This task adds no Keychain/UI behavior; those checks must be rerun when interactive access returns and before accepting new behavior there. No real Codex invocation is claimed for this coordinator task; ordinary execution tests use fake providers and synthetic storage.

## Commands and artifacts

All paths below are relative to the repository; `TestResults/` is ignored. Commands use the authorized local native toolchain. Failed and accepted attempts remain separate.

```sh
swift test --package-path Packages/AgentDeskCore --scratch-path TestResults/p1-11a/AgentDeskCoreBuild
swift test --package-path Packages/AgentDeskPersistence --scratch-path TestResults/p1-11a/AgentDeskPersistenceBuild
swift test --package-path Packages/AgentDeskRuntime --scratch-path TestResults/p1-11a/AgentDeskRuntimeBuild
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-11a/mac-unit-final.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -skip-testing:AgentDeskTests/KeychainIntegrationTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p1-11a/iphone.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build
codesign --verify --strict --verbose=2 TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app
codesign --verify --strict --verbose=2 TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app/Contents/XPCServices/AgentDeskCodexHost.xpc
python3 Scripts/validate-documentation.py
git diff --check
```

Package logs: `TestResults/p1-11a/AgentDeskCore.log`, `AgentDeskPersistence.log`, `AgentDeskRuntime.log`. Native failed attempt: `mac-unit.log` / `mac-unit.xcresult`; retry: `mac-unit-final.log` / `mac-unit-final.xcresult`. iPhone: `iphone.log` / `iphone.xcresult`; normal signed build: `normal-mac.log`. The documentation checker briefly reported the new validation link before this record was created; final documentation results are recorded before commit. Preexisting Xcode normalization, personal scheme metadata and handoff wording remain outside this task.
