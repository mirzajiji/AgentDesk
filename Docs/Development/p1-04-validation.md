# P1-04 SQLite operational persistence validation

Date: 2026-09-09. Starting commit `f0d4d91`, branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2. MacBook Pro arm64 on macOS 26.5.2 (25F84). Primary iPhone 16 Pro Simulator on iOS 26.0 (23A343), ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.

## Delivered behavior

`AgentDeskPersistence` provides an actor-confined system SQLite store for scoped run snapshots and ordered state events. It binds statement values, uses transactions and expected sequences, bounds reads/lock waits, handles cancellation/rollback and closes resources. Versioned migrations preserve prior records, reject unrelated/future schemas and never reset a failed database. New database files use owner-only creation permissions; database and sidecar links/non-regular files are rejected.

The package is linked into both native app platforms, and its shared tests are included in the Xcode unit target. This is run storage; live execution, lifecycle policy, provider text and UI history consumption remain later tasks. See [persistence contract](../Architecture/persistence.md).

## Commands and results

```sh
swift test --package-path Packages/AgentDeskPersistence
plutil -lint AgentDesk.xcodeproj/project.pbxproj
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' \
  -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-04/mac-final.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-01/NativeiPhonePrimary \
  -resultBundlePath TestResults/p1-04/iphone-final.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
python3 Scripts/validate-documentation.py
git diff --check
```

**PASS:** 12 persistence package tests; 47 native Mac unit executions; 44 native iPhone unit executions. Zero failures. Native counts also include the Core suite and platform app tests. Shared app builds and actual Simulator execution pass. No UI changed; the P1-03 full native UI acceptance remains applicable. The multi-device matrix stays deferred until full-project acceptance.

Tests cover reopen and paginated sequence replay; workspace/project predicates including identical run IDs across workspaces; stale/missing writes; two-connection concurrency; rollback when an event insert fails; cancellation after a transactional change; version-1 migration; failed migration and future schema preservation; corrupt/unrelated databases; symlink/hardlink/sidecar rejection; invalid limits/dates, duplicate IDs and injection-like parameter values. All files contain synthetic data in temporary directories.

The preliminary compile ran before test sources existed and reported no tests found; it was a compile check, not a passing test run. All final package/native commands above execute the completed tests successfully. Logs and results stay ignored in `TestResults/p1-04/`. Xcode's prior formatting-only project changes are retained alongside the new Persistence package/test wiring; no signing or identity settings changed.
