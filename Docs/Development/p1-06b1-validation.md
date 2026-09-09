# P1-06b1 shared instructions and effective preview validation

Date: 2026-09-09. Starting commit `6664313`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2. Native MacBook Pro arm64, macOS 26.5.2 (25F84). Primary iPhone 16 Pro Simulator, iOS 26.0 (23A343), ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.

## Behavior and exercise

This task adds scoped, versioned workspace/project instruction sets; bounded same-set include graphs; and an exact-source native preview in global/workspace/project/agent order. Sources retain their version, relative filename, text and SHA-256 fingerprint. The editor protects unsaved scope changes, failed loads and stale saves. See [configuration contract](../Architecture/configuration.md).

Before the regression suite, `swift build --package-path Packages/AgentDeskCore` passed and a standalone synthetic Swift smoke program exercised workspace guidance save, composition, source ordering and reopening. The program and executable remain ignored in `TestResults/p1-06b1/`. Its initial harness compile rejected an async call inside a synchronous assertion autoclosure; assigning the awaited result before the assertion fixed the harness. The corrected smoke passed.

## Commands and results

```sh
swift test --package-path Packages/AgentDeskCore
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' \
  -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-06b1/mac-first.xcresult \
  -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-01/NativeiPhonePrimary \
  -resultBundlePath TestResults/p1-06b1/iphone-first.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
```

**Passed:** 56 Core package tests, including 13 instruction-store/composer tests; 83 native Mac unit tests, including two new editor-model tests; 78 native iPhone unit tests. **9 native Mac UI executions also passed.** All native unit counts include the existing real Keychain integration checks, using only disposable synthetic entries.

The new regression cases cover absent/empty instruction sets, layer/include ordering, deduplication, unselected-file exclusion, a known SHA-256 value, exact agent snapshots, immutable files/history, frozen preview bytes, workspace inheritance with project isolation, foreign scopes and copied bundles, stale/concurrent stores, orphan recovery, symlinks/path substitutions, malformed-pointer preservation, cancellation, unselected cycles/missing references, duplicate identities and size/depth/content limits. Editor-model tests prove failed/unloaded scopes cannot be saved and stale failures preserve unsaved drafts.

The new native UI scenario creates a workspace/project/agent, saves project guidance, verifies that exact text and its Project source appear in the agent preview, and reopens the editor after app relaunch. Existing agent edit/archive/restore and workspace isolation/navigation checks run alongside it. Mac UI tests retain their random data-container identity and isolated window restoration arguments.

## Limits and retained work

Instruction sets contain human-authored text. This component never reads Keychain values, environment variables, arbitrary included filesystem paths, URLs or other-workspace data. It does not yet apply execution profile overrides, workflow/run layers, skill bundles or output schemas. Saving/editing does not run Codex or grant tools; the runtime policy gate is a separate later task. The iPhone has no instruction-administration UI. Broader device/runtime and physical-device acceptance remain deferred as recorded in [testing policy](testing.md).

Generated test data, result bundles, logs, smoke binaries and app-only screenshots remain ignored. The unrelated Xcode project-file ordering change is excluded from this task's commit.

The exported AgentDesk-only preview screenshot was visually inspected: scope/version headings, exact guidance, source disclosures, scrolling and Done remain readable within the minimum window. Screenshot: `TestResults/p1-06b1/mac-preview-attachments/624CC5E2-D1D0-4C6D-8EB6-80293B8359B1.png`. No source changes followed the accepted native runs. Documentation source/coverage/link/ignore checks and `git diff --check` pass. Accepted native builds report only unused App Intents metadata extraction warnings.
