# P1-01 native foundation validation

Date: 2026-09-09. Repository: `/Users/mirza/Documents/ChatGPT/AgentDesk/AgentDeskProject/AgentDesk`. Branch: `codex/native-foundation`. Starting commit: `4d027e9`. Environment: Xcode 26.0 (17A324), Swift 6.2 in Swift 6 language mode, arm64 MacBook Pro on macOS 26.5.2 (25F84).

## Delivered foundation

- Local Core and Design Swift packages, with role-specific navigation and shared native empty states.
- Native Mac split-view navigation for Workspaces, Runs and Connections; a truthful unpaired iPhone screen. Workspace creation, execution and secure pairing remain later tasks.
- A checked-in shared Xcode scheme with app, unit and UI targets. The app unit target reuses the Core package test sources so the same tests run on Mac and iPhone.
- macOS 15 and iOS 18 minimum deployment targets; native Mac+iPhone scope, Swift 6 concurrency checks. Existing signing and security settings remain intact.
- Core tests cover routing/restoration and invalid/cross-role destinations. Native UI tests cover launch, empty states, Mac sidebar navigation, appearance configurations, iPhone rotation and largest accessibility text.

## Permissions restored

Session approvals now allow authorized native tooling and network commands. `git push -u origin codex/native-foundation` succeeds (`Everything up-to-date`), confirming the documentation commit is on the personal remote. SwiftPM, Xcode and CoreSimulator now run normally with authorized access. The [earlier restricted-session record](p1-01-restricted-validation.md) is historical.

## Test evidence

`swift test --package-path Packages/AgentDeskCore`: **5 tests passed, 0 failures** through the ordinary SwiftPM runner.

`python3 -B -m unittest discover -s Scripts/tests -v`: **1 tooling regression test passed**. The supplementary source checker had also passed on Mac arm64/Intel and iPhone simulator/device compiler targets; these source checks are supplementary to the native runs below.

Mac native command:

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' \
  -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-01/native-mac-final.xcresult \
  -parallel-testing-enabled NO test
```

**PASS**: native signed build, app launch, 6 unit-test executions and 4 UI-test executions; 0 failures or skips. There are 9 distinct test cases, with the launch-configuration case executed twice. Mac model: MacBook Pro, arm64, macOS 26.5.2. The result summary is in ignored `TestResults/p1-01/native-mac-summary.json`.

Primary iPhone command:

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-01/NativeiPhonePrimary \
  -resultBundlePath TestResults/p1-01/iphone-16pro-final.xcresult \
  -parallel-testing-enabled NO test
```

Device: **iPhone 16 Pro**, iOS 26.0 (23A343), named `AgentDesk iPhone 16 Pro`. **PASS**: native Simulator build and launch, 6 unit-test executions and 7 UI-test executions, 0 failures or skips. There are 10 distinct cases, including a launch case repeated across four UI configurations. Result summary: `TestResults/p1-01/iphone-16pro-summary.json`. Normal and largest-accessibility-text screenshots were inspected: the unpaired state and complete message are readable.

## Updated testing scope

The user explicitly selected iPhone 16 Pro for development and deferred multi-device testing until the full project is complete. Native Mac tests continue throughout development. The [testing policy](testing.md) and [development instructions](../../AGENTS.md) record this update.

Before that change, a preliminary iPhone 16e/iOS 26 run passed (1 app unit and 6 UI executions). An optional SE/Pro Max matrix was started, then intentionally interrupted when the user changed scope. Partial matrix logs include passing tests on iOS 18.3.1, but the interrupted aggregate has incomplete result logs and is not counted as completed matrix coverage. Its cancellation is not a product failure.

Installed runtimes: iOS 18.3.1, 18.4 and 26.0. Exact minimum iOS 18.0 is unavailable. Final full-project acceptance must revisit minimum/current iOS versions and compact/large devices. Physical-device LAN testing also remains a later acceptance requirement.

## Review and continuation

Native Mac and primary iPhone results pass. Mac screenshot capture was narrowed to `app.windows.firstMatch.screenshot()` to avoid including unrelated desktop content; its two appearance launch checks pass separately in `TestResults/p1-01/mac-window-capture.xcresult`, and the exported app-only screenshot was visually verified. The rerun uses the Mac command above with result path `TestResults/p1-01/mac-window-capture.xcresult` and `-only-testing:AgentDeskUITests/AgentDeskUITestsLaunchTests`. Run documentation and staged diff checks, then commit this foundation separately. Continue with P1-02 scoped IDs/filesystem access. No phase as a whole is claimed complete by this foundation task.
