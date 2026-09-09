# P1-08b native Codex Settings and signed host validation

Date: 2026-09-09. Starting commit `6be270b`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2. MacBook Pro arm64, macOS 26.5.2 (25F84). Primary iPhone 16 Pro Simulator, iOS 26.0 (23A343), ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. The broader device/OS matrix remains deferred to final acceptance by user instruction.

## Behavior and authorization

The native Mac Settings window now shows Codex discovery/authentication facts, Health Check, browser Sign In, confirmed Sign Out, cancellation, explicit executable selection, automatic detection, and persisted Disconnect/Connect. Only nonsecret local configuration is stored. A failed or incompatible settings file is preserved and disables configuration. Unit tests cover account refresh/routing, cancellation and duplicate requests, path persistence, malformed/future settings and linked-file rejection.

The initial normal sandboxed app saw its own CLI home and reported signed out even though the terminal's supported status command found existing ChatGPT credentials. A separately signed private Mac XPC service now performs only prepared inspection/login/logout operations in the current user's context. Messages are bounded and typed; both connections validate exact peer bundle/team signatures. Concurrent work is rejected and invalidation cancels the subprocess session. The helper remains Mac-only and has no generic shell or LAN endpoint.

Automatic approval review initially rejected enabling an unsandboxed helper. The rejected command did not execute. After reviewing the [concrete proposal](native-codex-host-proposal.md), the user explicitly approved the signed Mac helper; the target was then added, built and exercised. Only its App Sandbox setting is disabled; the main app keeps App Sandbox, and both retain hardened runtime. This is not a root helper or a global security configuration change.

Normal LaunchServices testing also exposed that configuration initialization requested listing rights on parent folders outside the app's container. The trusted-container descriptor walk now requests search-only ancestor access with `O_SEARCH`, retaining no-follow validation at each component. The regression creates a search-only ancestor and proves contained reads/writes/listing and traversal rejection. The normal sandboxed workspace launch now presents its empty state without a catalog error.

## Commands and evidence

```sh
swift test --package-path Packages/AgentDeskCore
swift test --package-path Packages/AgentDeskRuntime
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-08b/mac-final.xcresult \
  -parallel-testing-enabled NO -test-timeouts-enabled YES \
  -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-08b/FilteredIPhone \
  -resultBundlePath TestResults/p1-08b/iphone-final.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
python3 Scripts/validate-documentation.py
git diff --check
```

Accepted package logs: `core-first.log` (67 tests), `runtime-first.log` (36 tests), under ignored `TestResults/p1-08b/`. The initial Settings compile needed an explicit Runtime import; this was fixed before accepted runs. Earlier unaffected Mac tests and helper builds are supplementary; final native evidence is recorded below. No generated output or credentials belong in Git.

The live native app health check reports Codex `0.153.4`, “ChatGPT credentials found,” and `/Applications/ChatGPT.app/Contents/Resources/codex`. This is a real read-only helper/CLI integration check. It proves neither network/token freshness nor a subscription plan/usage limit. Login/logout routing and cancellation are tested with fake services; the installed account was not signed out or sent through a new browser authorization flow. Agent runs do not exist yet, so active-run account handling belongs to the provider/coordinator gate.

Final acceptance: **140 Mac unit/integration, 10 Mac UI, and 115 iPhone unit/integration tests pass**. The first iPhone run also passed its tests, but a separate artifact inspection found that Xcode had discarded the original singular Mac platform filters, embedding the helper in the Simulator app. This was corrected with `platformFilters = (macos,)` on dependency, copy phase and copied product. A fresh derived-data iPhone run (`iphone-final.log/.xcresult`) passes all 115 tests, contains no XPC bundle and has no helper in its dependency graph. The full Mac result is `mac-final.log/.xcresult`; after the filter correction, `mac-filtered.log/.xcresult` reruns all 140 Mac unit tests and the Settings UI test successfully. That focused command is the Mac command above with `-only-testing:AgentDeskTests` and `-only-testing:AgentDeskUITests/AgentDeskUITests/testCodexSettingsHealthDisconnectAndReconnectPersistWithoutSigningOut`.

A normal signed build used `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build` and passed. `codesign -d --entitlements -` confirms the ordinary main app has `com.apple.security.app-sandbox = true` and the helper does not have that entitlement. Neither has Xcode's temporary test-only filesystem/Mach exceptions in this normal build. `codesign --verify --strict -R '=…'` passes each exact peer requirement from `CodexHostContract`. Initial restricted inspection and a missing inline-requirement prefix were inconclusive tool attempts; corrected verification with native access passed.

The normal app was launched via LaunchServices with a synthetic UUID data namespace and `-ApplePersistenceIgnoreState YES`. Native accessibility inspection shows a healthy empty workspace and the real Codex status above. Exported Settings window screenshot `Attachments/96512EDC-814D-405E-B4EC-61E9D8EF7E6F.png` was visually inspected: status, version, path, account controls and connection controls are visible and legible. UI tests also verify disabled actions after disconnect and persistence across relaunch. No live login/logout was invoked.

The staging candidate preserves unrelated existing Xcode ordering and historical-handoff wording edits; its parsed project graph matches the tested on-disk graph. Personal Xcode scheme UI metadata remains unstaged. Documentation integrity/159-section coverage/link/ignore checks and `git diff --check` pass. These results complete P1-08b; provider task streaming, policy, coordinator and active-run account handling remain separate required tasks.
