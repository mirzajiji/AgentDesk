# P1-05 scoped Keychain storage validation

Date: 2026-09-09. Starting commit `d88eca0`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2. MacBook Pro arm64 on macOS 26.5.2 (25F84). Primary iPhone 16 Pro Simulator, iOS 26.0 (23A343), ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.

## Implementation and passing checks

`AgentDeskSecurity` implements validated Codable secret references, an exact workspace/project/environment scope, a non-Codable value with redacted descriptions/dumps, the async SecretStore contract, and an actor-confined data-protection Keychain adapter. Values are device-local and require an unlocked device. Missing values and OS errors are distinct; existence does not retrieve bytes. Production has no plaintext or memory fallback. Fakes are test-only. See [security contract](../Architecture/security.md).

```sh
swift test --package-path Packages/AgentDeskSecurity
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-01/NativeiPhonePrimary \
  -resultBundlePath TestResults/p1-05/iphone-final.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
```

**PASS:** 7 isolated Security package tests and 53 native iPhone unit executions. The latter includes two actual Keychain integration tests: set/get/update, reopening, idempotent deletion, missing values and identical secret UUIDs in different environments. All native entries use synthetic values and random scope IDs, with exact-reference cleanup. There is no access to existing credentials or user accounts. The iPhone result precedes adding the Mac-only entitlement file; the final project regression also passes all 53 tests in `TestResults/p1-05/iphone-project-final.xcresult`.

## Native Mac acceptance and signing

The final Mac command passes **56 tests, zero failures**, including both native Keychain integration tests:

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' \
  -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-05/mac-login-recheck-1.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -allowProvisioningUpdates test
```

Xcode used the existing personal Apple Development identity and `Mac Team Provisioning Profile: com.mirza.AgentDesk`. The Mac-only entitlement file declares the existing team and product bundle identity, retaining sandbox/security settings. No shared access to another app's data was added. The final iPhone project regression also passes all 53 tests in `iphone-project-final.xcresult`; this uses the earlier iPhone command with that new result path. No UI changed, so P1-03 UI acceptance remains applicable.

Earlier Mac Keychain tests failed with `errSecMissingEntitlement` (-34018). The valid development certificate was already available; the app identity entitlement was missing. An early ad-hoc-signing diagnosis was incorrect and corrected after signed metadata inspection. Adding the entitlement required a development profile. Automatic approval review initially rejected creating/updating that profile; the user then explicitly approved it. The first approved attempt failed because Apple rejected Xcode's saved login. After the user signed in again, the same approved provisioning operation succeeded and all native tests passed. These failures are retained in the ignored result logs and are superseded by the successful final run. No app was published.

## Project-file interference

The first native builds could not find the Security module because the open Xcode workspace saved an older package graph over the file edits. The exact AgentDesk workspace was saved and closed (its paused debugging session was stopped), then package links were restored. Xcode's own app was not quit and no unrelated project was closed. Subsequent builds resolved the package correctly.

All source/configuration/test changes are preserved. Logs and results remain ignored under `TestResults/p1-05/`; no test output or secret values belong in the commit. Documentation integrity/link/ignore checks and `git diff --check` pass. Both native platforms now pass their actual tests; the task is ready for its focused commit.
