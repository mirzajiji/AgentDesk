# P1-12b scoped evidence storage and recovery

Date: 2026-09-10. Starting commit `14a583b`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, macOS 26.5.2 (25F84), arm64. Native iPhone tests ran on **AgentDesk iPhone 16 Pro**, **iOS 26.0 (23A343)**, ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. Broader device/minimum-runtime coverage remains deferred until full-project acceptance.

## Implemented and exercised

Schema 5 adds immutable run/environment/agent/configuration evidence bindings and ordered trace/artifact metadata. Registration requires an existing queued run and freezes the exact agent revision, effective configuration fingerprint and sanitized snapshot. All evidence writes require `RedactedText`; no raw provider output or arbitrary filename enters this API. Records retain classification, source, observed/interpretation basis, format hint, redaction metadata and the sanitized-content digest. Provider responses cannot be labelled observed evidence.

Traces live in SQLite. Artifact text lives in private files under exact workspace/project/environment/run IDs. No-follow descriptor operations reject symlinks, hardlinks and special files. Exclusive temporary writes, file synchronization, no-replacement atomic publication and directory synchronization precede the metadata commit. Reads verify type, size, UTF-8 and fingerprint before returning content.

Exact retry keys recover a matching orphan or missing file without changing evidence identity, timestamp or provenance. Metadata failure after file publication leaves an unpublished orphan. Recovery reports missing/corrupt/unsafe files and orphan/staging counts; it never deletes or exposes unknown contents. Corrupt/different files remain preserved and unavailable. Existing terminal runs permit exact repair retries but reject new evidence records. See the [persistence contract](../Architecture/persistence.md) for limits and durability assumptions.

This task implements storage and file reconciliation, not the provider-to-store coordinator, Git capture, native run views, automatic cleanup or binary artifacts. Storage is a lower-level component used after policy authorization. Startup handling of interrupted provider execution remains part of the coordinator task; artifact recovery does not imply the original run succeeded or can resume.

## Accepted validation

- **38 Persistence tests pass**, including 13 new evidence tests. They exercise registration and immutable snapshots, cross-workspace/project/environment/run/agent denial, ordered pagination/reopening, source/classification propagation, exact concurrent retries, conflicting payload/provenance rejection, failed SQL commits, orphan adoption, missing-file repair, corrupt-file preservation, symlink/hardlink/FIFO and foreign-directory denial, cancellation, filesystem permission failures, changed trace/foreign metadata rejection, capacity limits, staged-file reporting and forward migration/rollback from schema 4.
- The secret-exclusion test scans actual SQLite, sidecar and artifact bytes for the synthetic input secret after redaction. It also checks owner-only artifact permissions. Ordinary tests require no live Codex run, provider credentials, company data or external services.
- **240 native Mac unit/integration tests plus one Settings UI regression pass.** The new recovery/migration tests execute inside the signed app test target, alongside existing provider, policy and Keychain tests.
- **195 native iPhone unit/integration tests pass** on the primary local Simulator. File permissions, FIFO/link rejection, SQLite rollback and recovery are exercised there as well as on Mac.
- The normal signed Mac app builds. The task changes no provisioning, entitlements, XPC protocol or Xcode project graph.
- Documentation integrity, all 159 source-section ownership checks, links, ignore rules and whitespace checks pass. Preexisting Xcode normalization, personal scheme UI metadata and historical handoff text remain outside the commit.

The first implementation build passed the 25 preexisting persistence tests. The first new-test compile rejected synchronous directory enumeration from an async test; that assertion was moved to a synchronous helper. All accepted tests use the final helper. Existing prior-version migration assertions now correctly expect schema 5.

## Commands and records

Logs and result bundles are ignored under `TestResults/p1-12b/`: `persistence-accepted.log`, `mac-accepted.log/.xcresult`, `iphone-accepted.log/.xcresult` and `normal-mac.log`. The initial compile/test records remain in `first-build.log`, `evidence-tests.log` and `evidence-tests-fixed.log`.

```sh
swift test --package-path Packages/AgentDeskPersistence \
  --scratch-path TestResults/p1-12b/PersistenceBuild
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-12b/mac-accepted.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -only-testing:AgentDeskUITests/AgentDeskUITests/testCodexSettingsHealthDisconnectAndReconnectPersistWithoutSigningOut \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-08b/FilteredIPhone \
  -resultBundlePath TestResults/p1-12b/iphone-accepted.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build
python3 Scripts/validate-documentation.py
git diff --check
```
