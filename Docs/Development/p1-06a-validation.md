# P1-06a project agent editing validation

Date: 2026-09-09. Starting commit `63cfb0b`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2. Native MacBook Pro arm64, macOS 26.5.2 (25F84). Primary iPhone 16 Pro Simulator, iOS 26.0 (23A343), ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.

## Behavior

The native Mac project panel creates agents from eleven templates, edits instructions and requested Codex profile settings, and archives/restores agents. Each change creates an immutable JSON/Markdown revision and atomically advances its current pointer. Old revisions remain readable. Expected-revision checks prevent stale saves; active names are unique per project. File descriptors, scope validation and the catalog lock protect storage boundaries. A fresh lock descriptor per operation prevents separate actors sharing a root from bypassing serialization.

This is configuration editing. It does not start Codex, grant access, install skills, compose layered instructions or execute output schemas. Those capabilities retain their later task gates. See [agents and skills](../Architecture/agents-and-skills.md).

## Commands and results

```sh
swift test --package-path Packages/AgentDeskCore
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' \
  -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-06a/mac-third.xcresult \
  -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-01/NativeiPhonePrimary \
  -resultBundlePath TestResults/p1-06a/iphone-first.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
```

Package acceptance: **43 tests passed**, including 12 agent-store tests. Coverage includes immutable history/reopen, archive/restore/name reuse, stale edits, project scope and copied configuration, concurrent stores, orphan-version preservation, symlinked instructions, malformed pointers, cancellation, all templates, invalid profiles and shared-descriptor lock regression. Logs: `TestResults/p1-06a/core-tests.log`.

Native iPhone acceptance: **65 unit tests passed**, including shared agent storage and actual Keychain integration. This is a real local Simulator test run, not just a build. The agent editor is Mac-only; the iPhone remains the disconnected companion shell. No broad device/OS matrix was run for this task, following the user's development-device instruction.

Native Mac: **68 unit and 8 UI executions passed**, including real Keychain integration. UI coverage includes creation, instruction edit, archive, restore, reopening after relaunch, clean launch after window closure, workspace/project isolation, validation and sidebar navigation. Launch screenshots run in both available appearance configurations. The editor screenshot revealed that the fixed-height sheet extended beyond the minimum parent window; its height was reduced while keeping the instruction area scrollable. The focused final UI rerun passes (1 execution), and the exported app-only screenshot confirms the full editor, including Save/Cancel, fits inside the window. Its command is the Mac command above with `-only-testing:AgentDeskUITests/AgentDeskUITests/testAgentInstructionsPersistAcrossEditArchiveRestoreAndRelaunch` and result path `TestResults/p1-06a/mac-editor-final.xcresult`. Screenshot: `TestResults/p1-06a/mac-editor-attachments/11237186-E1AF-461B-9EFD-EDC1BFF92CCB.png`.

## Window-state test isolation

The first two Mac attempts passed all unit tests but failed every UI test because automated launches inherited saved window state and exposed only the menu bar. The desktop was logged in/on-console, and opening the same app normally showed its workspace window. A focused close-window/relaunch check passed after that normal launch. An exploratory launch-behavior modifier did not fix the automated suite and was removed.

Mac UI launches now pass `-ApplePersistenceIgnoreState YES`, alongside the existing random test-container identity. This is Apple's documented automated-test/debugging option; it ignores existing restorable state and redirects newly saved state to a temporary location. Normal app restoration and global preferences are unchanged. See [Apple AppKit release notes, Ignoring Existing Restorable State](https://developer.apple.com/library/archive/releasenotes/AppKit/RN-AppKitOlderNotes/). The suite checks launch after closing the previous window as well as disk-backed data reopening.

All fixtures and test inputs are synthetic. Screenshots capture only the AgentDesk window. Generated logs, result bundles, screenshots and runtime data remain ignored. The existing Xcode project-file ordering change is unrelated and excluded from this feature commit.

Documentation validation passes source integrity, all 159 sections, 34 owners, 21 required pages, 54 Markdown files, 304 local links and ignore checks. `git diff --check` passes. Native build warnings are limited to unused App Intents metadata extraction; no Swift compile warning or error was reported in the accepted runs.
