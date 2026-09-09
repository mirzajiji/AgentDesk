# Validation and iPhone Simulator coverage

## Per-task gate

1. Implement one coherent behavior and exercise its acceptance scenario.
2. Add or update meaningful unit tests for that behavior, including relevant failures and regression cases.
3. Run the unit suite and affected integration/UI checks. Shared changes must also build both native applications.
4. Review the diff and record exact checks, results, environment, and known limitations.
5. Commit the behavior and its tests together, separately from other tasks.

Documentation-only changes use document integrity/link checks instead of artificial unit tests. Missing executable targets, unavailable runtimes, denied simulator access, and unrun checks must be reported explicitly.

## Native testing layers

| Layer | Coverage |
| --- | --- |
| Swift unit tests | Domain validation, configuration composition, scoped paths, policies, run state, serialization, progress, and reducers |
| Persistence integration tests | Temporary isolated SQLite/filesystem stores, migrations, reopening, transactions, cross-workspace denials |
| Runtime integration tests | Fake executable/provider output, stderr, arguments/stdin, logged-out behavior, cancellation, timeout, cleanup, artifact/diff collection |
| macOS UI tests | Workspace/project/agent creation, instruction edits, run launch, live progress, result inspection, navigation, command palette, menu bar |
| iPhone unit/UI tests | Protocol decoding, list/detail navigation, empty/error/disconnected states, read-only diffs, permitted approval/cancellation, secret/shell denial |
| LAN integration tests | Pairing, unpaired/revoked rejection, scoped event streaming, replay/reconnect, duplicate events, permission denial, Mac sleep/wake |

Ordinary automated tests must use synthetic data, fake providers, and temporary stores. Do not require a paid/live Codex run or company services merely to test the code. Add explicit opt-in integration checks when real supported CLI behavior is being validated.

## Development device and final iPhone matrix

User update, 2026-09-09: use **iPhone 16 Pro** for routine development and keep native Mac unit/UI testing. Defer the broader device and OS matrix below until full-project acceptance. The current primary simulator is `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE` on iOS 26.0, named `AgentDesk iPhone 16 Pro`. Device identifiers are machine-local; enumerate replacements on other Macs.

Per-feature tests run the affected suites on Mac and this iPhone. The final matrix remains a release requirement.

Use Apple's local Simulator. A simulator build is necessary but is not equivalent to launching the app or running its tests. A web viewport or browser device emulation is not sufficient for this native application.

| Dimension | Required coverage once targets exist |
| --- | --- |
| Compact display | Smallest supported iPhone simulator available on the selected runtime |
| Large display | Supported Pro Max/Plus simulator or equivalent large iPhone |
| Minimum OS | Declared minimum supported iOS runtime |
| Current installed OS | Newest installed supported iOS runtime |
| Presentation | Light/dark appearance, portrait/landscape where supported, large accessibility text |
| Core flow | Launch, navigation, active run updates, details, diffs, approvals and error states as implemented |

Set minimum deployment targets during the native scaffold task based on required APIs and the locally available SDKs/runtimes; do not confuse installed device-type profiles with installed usable runtimes. Test both size classes across OS versions where available. If only one OS runtime is installed, report that gap and arrange installation rather than claiming multi-version coverage.

Device discovery commands:

```sh
xcodebuild -version
xcrun simctl list runtimes
xcrun simctl list devices available
```

The Xcode project has `AgentDesk`, `AgentDeskTests`, and `AgentDeskUITests` targets and a checked-in shared `AgentDesk` scheme. P1-01 adds local Core/Design packages, five Core tests, an app routing test and native UI checks. The Core suite passes through ordinary SwiftPM and the native Xcode app unit target. Native Mac and iPhone test access is restored. See [P1-01 validation](p1-01-validation.md) for the distinction between source checks, host tests and native acceptance.

Mac UI launches use a random `AGENTDESK_TEST_CONTAINER_ID` for synthetic data and `-ApplePersistenceIgnoreState YES` to isolate window restoration between tests. The latter is limited to test process arguments; normal app restoration remains enabled. See [agent editor validation](p1-06a-validation.md) for the observed failure and resolution.

Save generated `.xcresult` bundles and screenshots under ignored `TestResults/`. Record the app version/commit, Xcode version, simulator model/UDID, exact iOS version, command, pass/fail counts, and any manual inspection. CI supplements the requested local simulator testing; it does not replace it.

Real device validation remains separately required for final LAN acceptance, including local-network privacy, hardware device authentication, background/foreground, Wi-Fi transitions, and Mac sleep/wake. Simulator testing alone cannot establish all of those behaviors.
