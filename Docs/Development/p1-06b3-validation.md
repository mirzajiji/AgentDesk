# P1-06b3 versioned skills and agent references

Date: 2026-09-10. Starting commit `c3f16eb`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, macOS 26.5.2 (25F84), arm64. Native iPhone tests ran on **AgentDesk iPhone 16 Pro**, **iOS 26.0 (23A343)**, ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. Broader device/minimum-runtime acceptance remains deferred by the user until the full project is built.

## Implemented and exercised

Workspace/project skills now have immutable bundle revisions: `skill.json`, `instructions.md` and optional example/script text attachments. Manifests bind exact ownership, filenames, permissions, state and file fingerprints. All scope/path/content validation uses bounded no-follow storage. Unknown fields, duplicate JSON keys, wrong hashes, unsupported versions, unsafe names and links fail closed. Writes preserve history, reject stale editors and skip orphan revisions.

The native Mac **Agents → Skills** panel creates, edits, disables, archives and restores skills. The editor manages name/description, project/workspace scope, instructions, requested permissions and attachments; scope cannot change after creation. Attachments can be added, edited, removed and previewed, but scripts are never executed. The agent's **Skills** tab attaches exact revisions, retains old pins on edits, allows explicit version updates and removal of unavailable references. Instruction preview resolves the pinned bytes, shows their provenance and lists permission requests separately.

Agent saves and previews reject foreign, missing, disabled or archived skill references. The current skill must remain available even when the agent pins an older version. Adding a skill does not alter execution policy or grant permissions. The complete encoded agent manifest is now bounded before publication, preventing new reference/schema metadata from creating a saved revision that exceeds its read limit. Historical agents without skill fields remain readable; normal edits preserve refs and archive does not delete history.

See the [skill contract](../Architecture/agents-and-skills.md) for exact storage layout, native flow and limits. Rich input/output/tool metadata, external bundle import/discovery, actual script execution and workflow integration remain later work. The run coordinator must freeze the composed instructions and configuration together, authorize concrete operations and persist redacted run snapshots.

## Accepted tests and native checks

- **97 Core tests pass.** New coverage includes create/edit/reopen/history, expected revision failures, orphan preservation, inert nonexecutable attachments, exact pinned instruction sources, permission requests without policy grants, agent reference preservation/removal, current disabled/archive blocking of historical pins, restore, workspace sharing, cross-workspace/project denial, invalid permissions/refs/filenames/size, duplicate names/files, symlink/hardlink/path/scope/hash/unknown-field/duplicate-key attacks, cancellation and malformed pointers. Additional regressions cover atomic attachment edits in unfinished drafts and oversized agent manifest rejection without publishing an unreadable revision.
- **68 Runtime tests pass** against the final shared Core code. Skill composition does not enable ambient CLI skill discovery or extend the signed XPC account interface.
- **215 native Mac unit/integration tests pass**, including the new skill model stale-save/failed-reload check and existing Core, Runtime, persistence, policy and Keychain checks.
- **11 distinct Mac UI executions pass across the broad run and focused retry:** ten existing UI executions (including two launch configurations) passed in `mac-complete`; the new skill/attachment/pinning/preview/relaunch flow passes in `mac-skill-final`. The original broad result bundle remains marked failed because the first version of the new test used an incorrect accessibility selector; it is not represented as a clean full-suite run.
- **170 native iPhone unit/integration tests pass** on the primary Simulator. These exercise shared skill storage and composition; the Mac-only editor does not appear on the companion.
- The **normal signed Mac app build passes**. App and helper signatures validate through system trust; the main app remains sandboxed and the previously approved helper remains without App Sandbox. A normal LaunchServices launch with an isolated `AGENTDESK_TEST_CONTAINER_ID` opens the native Workspaces window with the expected empty state. No signing, provisioning, XPC API or project graph changes belong to this task. The iPhone product contains no XPC bundle.

The synthetic unit fixture is an evidence-review skill with example Markdown and a script that would create `SHOULD_NOT_EXECUTE` if run. Its text is saved with mode 0600, its marker is absent, and scripts/examples do not enter the automatic composed prompt. No live company service, model call, secret value or login/logout change is required by this task's tests.

## Commands and evidence

Logs, screenshots and `.xcresult` bundles are ignored under `TestResults/p1-06b3/`. Accepted final records: `core-accepted.log`, `runtime-final.log`, `mac-accepted.log/.xcresult` (215 unit tests; its final checkbox assertion was subsequently corrected), `mac-skill-final.log/.xcresult` (complete new UI flow), `iphone-accepted.log/.xcresult`, and `normal-mac-final.log`. Existing UI regressions passed in `mac-complete.log/.xcresult`. The native preview screenshot exported under `Attachments/` was visually inspected for readable text, navigation and source disclosure layout.

```sh
swift test --package-path Packages/AgentDeskCore
swift test --package-path Packages/AgentDeskRuntime --scratch-path TestResults/p1-06b3/RuntimeBuild
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-06b3/mac-complete.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests -only-testing:AgentDeskUITests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-06b3/mac-accepted.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -only-testing:AgentDeskUITests/AgentDeskUITests/testSkillCreationPinningPreviewAndReopen \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-06b3/mac-skill-final.xcresult \
  -parallel-testing-enabled NO \
  -only-testing:AgentDeskUITests/AgentDeskUITests/testSkillCreationPinningPreviewAndReopen \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 120 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-08b/FilteredIPhone \
  -resultBundlePath TestResults/p1-06b3/iphone-accepted.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build
python3 Scripts/validate-documentation.py
git diff --check
```

The first native compile exposed a missing Combine import; the model was separated from the view with the proper import. UI test iteration established that macOS exposes these controls as **Tab**, not RadioButton/Button, and the checkbox value is numeric. The final test uses the observed native accessibility roles and numeric checked value. Functional steps before those incorrect assertions had succeeded; the full corrected skill flow now passes in 54 seconds. Those failed attempts remain in their original records.

The final review excludes preexisting Xcode formatting/normalization, personal scheme UI metadata and historical handoff text. All 159 architecture sections, documentation links/coverage and ignore checks pass. No runtime output, credentials or company data belongs in the commit.
