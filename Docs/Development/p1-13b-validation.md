# P1-13b native execution setup and current-context preparation

Date: 2026-09-10. Starting commit `d0647dc`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, macOS 26.5.2 (25F84), arm64. Primary Simulator: AgentDesk iPhone 16 Pro, iOS 26.0 (23A343), `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. Broader device/minimum-runtime acceptance remains deferred.

## Scope

A project-bound native setup service reads a consistent workspace/project editor snapshot, saves through immutable revision checks and proposes editable defaults only for missing documents. No read or proposal writes files, fills omitted policies or grants authority. The explicit read-only proposal creates one Development environment at project scope and requires review for read-only runs at all policy layers. Existing settings, advanced restrictions and missing-policy denial remain intact.

Current-context preview resolves the exact agent, instruction sources/pinned skills, environment and effective configuration twice. Different observations fail explicitly instead of being combined or retried indefinitely. Revalidation preserves default-versus-explicit environment selection and detects changed agent/instructions/settings, disabled environments and archived agents. The native preparation overload revalidates before creating a run. It still uses the existing exact policy and approval boundary; previews do not authorize execution.

The native UI owner must propagate active policy updates or shut down the run service before replacing execution settings. The service does not add a configuration watcher or claim atomicity across later UI interactions. UI forms/inspector/console remain P1-13c. This task does not change app/helper entitlements or make a live model request.

## Results and limitations

**106 Core, 113 Runtime, 295 affected native Mac unit/integration and 224 native iPhone tests pass.** Six new Core tests cover no-write reads/proposals, explicit reviewed defaults, preserved advanced settings and history, competing revision saves, latest-source context refresh, environment/policy changes, archive/disable behavior, scope isolation, malformed input and cancellation. One new native-service integration test proves stale context creates no run/provider request; refreshed context enters approval wait and executes only after review, using the revised instructions.

The existing 100 Core tests first passed while exercising the implementation. The first focused suite exposed an overly narrow test expectation: a competing writer may receive the catalog's documented nonblocking `busy` result before reaching the revision check. The test now accepts only `busy` or `staleRevision` for the losing writer and verifies one winner and preserved scoped data. The first Runtime build reused a stale SwiftPM dependency source list and could not see the new Core file; a fresh scratch build discovers it and passes all 113 tests. Neither initial failure is counted as success.

The normal signed Mac build and strict app/helper signature verification pass. Native UI and the two unchanged Keychain integration tests remain unavailable under the macOS authentication condition recorded in [repository validation](p1-13a-validation.md); they are excluded from the passing counts and were not redundantly retried. The iPhone log also retains existing synthetic-test cleanup diagnostics about an SQLite vnode unlinked while a fixture still holds a connection (confirmed in the prior P1-13a log). Assertions pass, but these diagnostics are not described as a clean log; fixture lifetime cleanup remains follow-up validation work.

## Reproduction and artifacts

Ignored output lives under `TestResults/p1-13b/`: `core-exercise.log`, initial `core.log`, accepted `core-final.log`, initial `runtime.log`, accepted `runtime-final.log`, `mac-unit.log` / `mac-unit.xcresult`, `iphone.log` / `iphone.xcresult`, and `normal-mac.log`. All data/providers are synthetic.

```sh
swift test --package-path Packages/AgentDeskCore --scratch-path TestResults/p1-13a/CoreBuild
swift test --package-path Packages/AgentDeskRuntime --scratch-path TestResults/p1-13b/RuntimeBuild
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-13b/mac-unit.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -skip-testing:AgentDeskTests/KeychainIntegrationTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p1-13b/iphone.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build
codesign --verify --strict --verbose=2 TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app
codesign --verify --strict --verbose=2 TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app/Contents/XPCServices/AgentDeskCodexHost.xpc
python3 Scripts/validate-documentation.py
git diff --check
```

Documentation integrity/159-section coverage, local links, ignore rules and diff checks pass. Diff review excludes the three preexisting Xcode/project-handoff changes. No generated output, company data or credentials are staged. Effective personal author/committer and the exact supplied personal GitHub remote are verified before commit/push.
