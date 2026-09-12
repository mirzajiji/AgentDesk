# P3-08 native MCP manager validation

## Configuration editor

Connections now offers Jira/MCP selection for the current project. The MCP screen lists saved local configurations with revision/enabled state and supports creation and editing. The editor provides persistent field labels, separate literal argument fields with add/remove, environment selection, and enable/disable. Editing preserves scoped credential references and environment identity; it does not start a process. The model reloads current environments, validates scope, saves with expected revision and pages published heads. Late cancelled loads do not replace current UI state.

The Xcode app and test targets now directly link AgentDeskMCP. The first test build exposed undefined MCP symbols; explicit product linkage fixed this. Existing unrelated Xcode project normalization is preserved outside this commit.

## Validation

macOS 26.5.2 / Xcode 26.0. Synthetic temporary catalog only; no live MCP server or credentials.

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-08-native-arguments.xcresult -only-testing:AgentDeskTests/ProjectMCPConnectionsModelTests -only-testing:AgentDeskUITests/NativeMCPConnectionsUITests -parallel-testing-enabled NO test
```

Passed: one native model regression covering save/reopen/versioning/stale edits/invalid executables, and one native UI regression covering create, argument add/remove, save and reopen. An intermediate UI test failed to compile due to an incorrect selector; the corrected final run passes. Exported final screenshot visually inspected: field labels remain visible and controls fit inside the sheet.

Normal Mac and iPhone builds passed:

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac build
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone build
```

Logs: `TestResults/p3-08-mac-build.log`, `TestResults/p3-08-iphone-build.log`, `TestResults/p3-08-native-arguments.log`. iPhone 16 Pro / iOS 26.0 build only for this Mac UI task; no new iPhone test coverage claimed. Documentation/diff checks pass.

P3-08 remains in progress: native reviewed start/stop/restart, credentials, remote transport, deletion, capability/permission browsing, health and logs still require implementation and acceptance. Counts remain 52 tasks complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

The editor now offers Workspace or Registered repository directory bases. Empty subdirectory selects the registered repository root; workspace-relative paths remain mandatory. Native save/reopen coverage passes for this selection. See the [directory-base validation record](p3-06-validation.md) for package, runtime, Simulator and native build results. Native process-start controls remain unfinished.

## Reviewed native connection lifecycle

Enabled connections now open a native lifecycle sheet with the saved executable, literal arguments, directory base, environment and credential variable names. Review Start prepares a runtime approval; process launch follows explicit approval, with a separate credential review when policy requires it. Connected sessions offer a ping health check. Stop, cancellation and sheet dismissal close the runtime session. Opening validates the displayed configuration revision before and after runtime preparation; subsequent policy/configuration changes remain checked by the runtime gate.

The UI model owns cancellation and rejects late open/start results. Errors use fixed messages. The normal host uses registered repository access, scoped Keychain references, current project/environment policy and a persisted ApprovalStore. This does not extend the Mac helper or bypass the app sandbox. The lifecycle view is session-local; closing it stops the process. Credential editing, persistent connection monitoring/logs, discovery and tool permissions remain outstanding.

Validation on macOS 26.5.2 / Xcode 26.0:

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-08-lifecycle-v3.xcresult -only-testing:AgentDeskTests/NativeMCPLifecycleModelTests -only-testing:AgentDeskTests/ProjectMCPConnectionsModelTests -only-testing:AgentDeskUITests/NativeMCPConnectionsUITests -parallel-testing-enabled NO test
```

Passed: six unit tests and one UI test. Lifecycle unit coverage includes separate credential approval, denied credential access, health checks, late startup/open cancellation, repeated stop and fixed failure messages. The UI test creates/enables/reopens a synthetic configuration and verifies command details, initial review gating and stop controls; it does not approve or launch `/usr/bin/true`. Actual stdio launch/approval/ping/shutdown is covered by the preceding runtime integration record, not claimed as a live native UI launch here. Exported lifecycle screenshot visually inspected: command details and primary controls fit without clipping. Initial compile misses were corrected. One intermediate UI runner timed out enabling automation before UI assertions; the recorded retry passed.

Normal signed Mac build passed (`TestResults/p3-08-lifecycle-final-build.log`). Documentation validator and diff whitespace checks pass. All changed app code is macOS-only; no new iPhone Simulator coverage is claimed. P3-08 remains in progress, with 52 tasks complete and 11 Phase 3 tasks plus Phases 4–6 remaining.

## Native stdio acceptance

Added a Debug-only, UUID-container-gated fixture that creates an app-owned synthetic Git repository, registers it through the production repository service, saves an approval-required environment policy and configures a real stdio MCP server. The UI test uses the normal WorkspaceBrowserModel and NativeMCPConnection path without replacing the provider, policy gate, approval store or process runner. It requires review and approval, checks ping health, stops, and repeats with a fresh review. No user repository, credential, external service or helper entitlement is used.

The first native launch exposed a fixture limitation: `/usr/bin/python3` is an xcrun shim, and xcrun explicitly refuses App Sandbox execution. Resolving via xcrun inside the UI runner failed for the same reason. The final fixture uses the verified direct interpreter at `/Applications/Xcode.app/Contents/Developer/usr/bin/python3` (or the runner's DEVELOPER_DIR equivalent). Temporary raw synthetic diagnostics were removed; production error/redaction behavior is unchanged. This does not claim every installed MCP executable works inside the Mac sandbox.

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-08-native-stdio-interpreter.xcresult -only-testing:AgentDeskTests/NativeMCPLifecycleModelTests -only-testing:AgentDeskUITests/NativeMCPConnectionsUITests -parallel-testing-enabled NO test
```

Passed on macOS 26.5.2 / Xcode 26.0: five model unit tests and two native UI tests, including two actual approved process lifecycles. Log: `TestResults/p3-08-native-stdio-interpreter.log`. Normal signed Mac build passed (`TestResults/p3-08-native-stdio-build.log`). Documentation/diff checks pass. This extends native Mac acceptance only; no new iPhone run is claimed. P3-08 remains incomplete for credentials editing, deletion, capability/permission browsing, remote transport and persistent diagnostics. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Stop during failed-connection cleanup

A delayed-close regression reproduced a race: failure handling released the model's session reference before awaiting cleanup, so Stop could immediately display Stopped and permit another review while that cleanup was still pending. Failure handling and Stop now retain and join the same cleanup chain. Cancellation of the UI operation does not cancel its process cleanup. Stop remains busy until the chain finishes; repeated Stop does not enqueue duplicate closes.

The new test failed against the previous implementation (`TestResults/p3-08-cleanup-before.xcresult`), then passed with the fix. Final command:

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-08-cleanup-after.xcresult -only-testing:AgentDeskTests/NativeMCPLifecycleModelTests -only-testing:AgentDeskUITests/NativeMCPConnectionsUITests/testReviewedNativeProcessStartHealthStopAndRestart -parallel-testing-enabled NO test
```

Passed on macOS 26.5.2 / Xcode 26.0: six lifecycle unit tests and one real-process native UI test. Normal signed Mac build passed (`TestResults/p3-08-cleanup-build.log`); documentation/diff checks pass. No new iPhone coverage is claimed for this Mac-only model fix. Task counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.
