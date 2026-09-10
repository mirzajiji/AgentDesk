# P1-13a native repository registration and access

Date: 2026-09-10. Starting commit `ca83754`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, macOS 26.5.2 (25F84), arm64. Primary Simulator: AgentDesk iPhone 16 Pro, iOS 26.0 (23A343), `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. Broader device/minimum-runtime acceptance remains deferred by the user.

## Scope and behavior

A native project-scoped service registers an explicitly selected ordinary Git root, validates safe Git configuration/worktree identity and persists a bounded private JSON registration with a read-only security-scoped bookmark. It verifies catalog membership and exact physical resource identity, rejects stale/moved/replaced selections and preserves existing data on malformed input, cancellation or revision conflict. Shared access leases keep multiple readers safe while preventing registration replacement/removal during use; removal never removes the repository. Native run services retain the OS grant until shutdown and record selected-directory/registration provenance through the redactor, without exporting bookmark bytes.

The registry's trusted application-support directory is machine-local, outside portable workspace configuration. Its bookmark records are not backup/export/mobile data. The main app adds the app-scoped bookmark declaration documented by [Apple](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access), retaining App Sandbox and user-selected read-only access. The helper's existing approved boundary is unchanged. No live Codex request or account change is needed for this task.

P1-13 is split into repository service (this task), execution setup service (P1-13b) and native UI assembly (P1-13c). The external folder picker, relaunch access, settings/context inspector, console and approval UI are not claimed complete by these service tests. Editable repository remote/default-branch/role configuration remains later work.

## Results

**100 Core tests, 112 Runtime tests, 288 affected native Mac unit/integration tests and 218 native iPhone tests pass.** Three new Core tests cover bounded configuration JSON and duplicate-key rejection. Six new Runtime tests cover real synthetic Git preflight, reopening, revision conflicts, shared access, scope isolation, malformed/linked records, cancellation, changed storage/repository roots and native service grant retention. The preparation test checks exact location provenance and absence of opaque bookmark data in persisted run evidence.

One new signed native integration test creates a real read-only OS bookmark, reopens its record, retains access and verifies removal protection/cleanup. It is included in the 288 Mac count; focused runs are not added again. A final focused run after the entitlement declaration also passes. Its synthetic repository is inside the app container: it does **not** prove external-folder picker or post-relaunch sandbox access.

The normal signed Mac build passes. App and helper signatures pass strict verification. The app has `app-sandbox`, `files.user-selected.read-only` and `files.bookmarks.app-scope`; the helper retains its prior entitlements. Xcode reports the existing App Intents metadata warning because the target does not use AppIntents.

## Interactive checks still unavailable

A separate recheck of the two unchanged Mac Keychain integration tests fails with `-25308` (`errSecInteractionNotAllowed`). Native UI runner initialization fails with `com.apple.LocalAuthentication Code=-4`, reporting “System authentication is running” and “Authentication canceled.” Both the combined interactive check and a separate UI retry record this environment failure. These checks are not counted as passing. The user has been asked to finish pending macOS authentication when available; ordinary backend work continues. No claim of an unlocked session or normal foreground launch is made. Native external-folder/relaunch and UI acceptance remain pending P1-13c.

## Reproduction and output

Ignored logs and result bundles are under `TestResults/p1-13a/`. Initial service runs use `core.log`, `runtime.log`, `mac-unit.log`, `iphone.log` and `mac-bookmark.log`. Final source regression logs are `runtime-final.log`, `mac-final.log` and `iphone-final.log`. Final entitlement integration is `mac-bookmark-final.log`; normal signing build output is `normal-mac.log`. Interactive failures are in `interactive-check.log` / `interactive-check.xcresult` and `ui-check.log` / `ui-check.xcresult`.

```sh
swift test --package-path Packages/AgentDeskCore --scratch-path TestResults/p1-13a/CoreBuild
swift test --package-path Packages/AgentDeskRuntime --scratch-path TestResults/p1-13a/RuntimeBuild
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-13a/mac-final.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -skip-testing:AgentDeskTests/KeychainIntegrationTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p1-13a/iphone-final.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p1-13a/mac-bookmark-final.xcresult -parallel-testing-enabled NO -only-testing:AgentDeskTests/RepositoryBookmarkIntegrationTests -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build
codesign --verify --strict --verbose=2 TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app
codesign --verify --strict --verbose=2 TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app/Contents/XPCServices/AgentDeskCodexHost.xpc
codesign -d --entitlements - TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app
codesign -d --entitlements - TestResults/p1-08b/NormalMac/Build/Products/Debug/AgentDesk.app/Contents/XPCServices/AgentDeskCodexHost.xpc
python3 Scripts/validate-documentation.py
git diff --check
```

Documentation integrity, all 159 source-section coverage, local links, ignore rules and diff checks pass. Staging excludes preexisting Xcode project normalization, personal scheme metadata and handoff wording. Test output, company data and credential material are not staged. Personal author/committer and the exact personal GitHub remote are verified before commit/push.
