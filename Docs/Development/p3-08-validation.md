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

## Scoped credential configuration service

`NativeMCPCredentialEditor` adds the local administrative set/replace operation needed by the native credential editor. It validates project/environment scope, variable syntax and process-compatible UTF-8 values before secret writes. Each change allocates a new SecretReference, stores the SecretValue through the scoped SecretStore, then publishes an immutable configuration revision using compare-and-swap. No value is encoded in configuration. Existing references are retained for immutable history; replacement is not revocation, and deleting historical credentials requires a separate operation.

If secret storage or configuration publication fails, cleanup attempts to delete the newly allocated reference even when the calling UI task was cancelled. If cleanup itself fails, the typed error carries only the reference that needs recovery. This is an internal native administrative capability, not an MCP tool, mobile operation or completed credential-entry UI. Runtime reads still require their independent readSecret policy decision.

Validation on macOS 26.5.2 / Xcode 26.0: `swift test --package-path Packages/AgentDeskRuntime` passed all 197 tests (`TestResults/p3-08-credential-runtime.log`). Six new isolated tests cover replacement/history, malformed values and variable names, stale writes, a competing configuration update after secret creation, cancellation-safe rollback, partial-write cleanup failure and foreign SecretStore rejection. Tests use a synthetic SecretStore; no live Keychain credential was written. Normal signed Mac build passed (`TestResults/p3-08-credential-build.log`). Documentation and whitespace checks pass. Mac-only API; no new Simulator run claimed. P3-08 remains in progress; counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Native secure credential entry

Connections now expose a Credentials sheet with configured variable names, a variable-name field and a native SecureField. The production write path creates a project/environment-scoped KeychainSecretStore and delegates to NativeMCPCredentialEditor with the displayed revision. Existing values are never read into the UI. Submission clears the entry immediately, prevents duplicate writes, and refreshes connection configuration on dismissal. Cancel waits for save/rollback before dismissal; a rollback failure keeps its reference-only recovery message visible for acknowledgment. Replacement remains separate from revocation.

Validation on macOS 26.5.2 / Xcode 26.0:

- Four native model tests passed (`TestResults/p3-08-credential-recovery.xcresult`): one write per submission, empty-input rejection, fixed error messages, value clearing, late-success suppression, awaited cancellation and recovery-reference retention after rollback failure. Writes are injected synthetic operations.
- Native configuration/credential UI regression passed (`TestResults/p3-08-credential-ui-final.xcresult`): opens Credentials, enters a synthetic masked value, cancels, reopens and checks the field is empty. This test does not save a real Keychain item. The exported secure-field screenshot was visually checked for masking, readable layout and reachable actions.
- Normal signed Mac build passed (`TestResults/p3-08-credential-ui-build.log`). Documentation validator and whitespace checks pass. This is Mac-only UI; no new iPhone run is claimed.

Commands use the existing native test invocation with `-only-testing:AgentDeskTests/NativeMCPCredentialModelTests` and `-only-testing:AgentDeskUITests/NativeMCPConnectionsUITests/testCreateAndReopenConfiguration`; the recovery follow-up ran the model class alone. Native Keychain save/read-through acceptance, revocation, connection deletion, capability/permission browsing, remote transports and persistent diagnostics remain outstanding. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Signed native Keychain-to-MCP acceptance

Added a signed app-host integration test that uses the production credential model, WorkspaceBrowserModel save/open services, KeychainSecretStore, immutable MCP configuration store, repository registry, approval store and native stdio process. It creates a unique synthetic workspace/project/environment and repository. Saving clears the input and publishes a reference-only revision; reopening Keychain returns the expected synthetic value. Launch remains disconnected after process approval until the separate credential approval is granted. The real server then reads the credential from its environment and echoes it as its identity; the native model receives a redacted identity and a successful ping. Stop completes and the test deletes and verifies removal of its exact Keychain reference. Failure cleanup also targets only that reference.

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-08-keychain-native-final.xcresult -only-testing:AgentDeskTests/NativeMCPCredentialIntegrationTests -only-testing:AgentDeskTests/KeychainIntegrationTests -parallel-testing-enabled NO test
```

Passed on macOS 26.5.2 / Xcode 26.0: three native integration tests, zero failures (`TestResults/p3-08-keychain-native-final.log`). The new test explicitly verifies the serialized connection revision contains no credential value. It uses the installed direct Xcode Python interpreter to avoid the sandbox-incompatible xcrun shim. This is a native model/service integration in the signed app, not an additional mouse-driven credential-save UI test. The existing secure-field UI regression remains the visual/input coverage. No real account credential or company service was used; no new iPhone coverage claimed. Product code is unchanged by this test-only task. Documentation and diff checks pass. Revocation, deletion, discovery/permissions, remote transport and persistent diagnostics remain outstanding; counts stay 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Credential variable-name launch boundary

MCP configuration accepts ASCII environment-variable names up to 128 bytes, but MacProcessRunner previously rejected names above 100 bytes. A regression using a validated MCP configuration and a real `/usr/bin/env` child reproduced the launch failure. The runner now accepts the same 128-byte name limit. A 129-byte name still fails before child output; existing environment count, aggregate-byte, NUL and equals-sign validation remains intact.

Validation on macOS 26.5.2 / Xcode 26.0:

- The focused regression failed before the fix (`TestResults/p3-08-variable-limit-before.log`).
- `swift test --package-path Packages/AgentDeskRuntime` passed all 198 tests (`TestResults/p3-08-variable-limit-after.log`).
- Signed native Keychain-to-MCP integration passed using the standard native test command with `-only-testing:AgentDeskTests/NativeMCPCredentialIntegrationTests` and result bundle `TestResults/p3-08-variable-native.xcresult` (`TestResults/p3-08-variable-native.log`). Its app host built successfully.
- Documentation and whitespace checks pass. The runner is macOS-only; no new iPhone coverage is claimed. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Native tool discovery

The running connection screen now offers Discover Tools and a separate Approve Tool Discovery action when required by the current scoped policy. The host grants the local user's read-evidence operation to the policy engine; this does not bypass workspace/project/environment rules. The view displays only the runtime's redacted names, titles and descriptions, labels annotation hints as server claims, and provides no tool execution control. Stop clears the catalog and cancels the pending request. Generation checks prevent late discovery results from restoring a stopped connection; denied/failed discovery uses fixed diagnostics and closes the session.

Connection controls now sit outside the scrollable details area. The real UI regression exposed that long command arguments could otherwise push Check Health below the viewport. Keeping controls fixed makes approval, discovery, health and Stop reachable while details and tool cards scroll.

Validation on macOS 26.5.2 / Xcode 26.0:

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-08-discovery-ui-visible.xcresult -only-testing:AgentDeskTests/NativeMCPLifecycleModelTests -only-testing:AgentDeskUITests/NativeMCPConnectionsUITests/testReviewedNativeProcessStartHealthStopAndRestart -parallel-testing-enabled NO test
```

Passed: 9 native model tests and 1 native UI test, zero failures (`TestResults/p3-08-discovery-ui-visible.log`). The UI test performs two real synthetic process start/discovery approval/health/stop cycles, verifies the displayed tool title through macOS accessibility and scrolls the card into view. The exported screenshot was visually inspected: the tool card, hints and fixed controls are visible. New model regressions cover separate review, empty catalog, denial with fixed diagnostics, stop clearing results and cancellation with late completion.

Earlier attempts recorded a missing view import (`p3-08-discovery-ui.log`), the unreachable health control (`p3-08-discovery-ui-final.log`), and an accessibility assertion reading label instead of macOS static-text value (`p3-08-discovery-ui-footer.log`). Each was corrected before the passing run. Normal signed Mac build passed with the standard Mac build command (`TestResults/p3-08-discovery-ui-build.log`). Documentation/diff checks pass. This Mac-only change adds no iPhone Simulator coverage; physical display matrix remains deferred.

Discovery UI is implemented, but schema browsing, tool invocation, resources/prompts and the remaining MCP management/transport scope keep P3-07/P3-08 in progress. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Native prompt browsing

The running MCP connection now offers Discover Prompts, an independent Approve Prompt Discovery review when required, and scoped redacted prompt cards. Cards show prompt and argument names/titles/descriptions and optional required flags. Discovery only lists descriptions: it does not fetch prompt messages or adopt instructions. Empty results have an explicit state. Stop and failure clear prompt results; generation/cancellation checks prevent late responses from restoring a stopped catalog. Existing tool discovery remains independently reviewable.

Validation on macOS 26.5.2 / Xcode 26.0:

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-08-prompt-ui.xcresult -only-testing:AgentDeskTests/NativeMCPLifecycleModelTests -only-testing:AgentDeskUITests/NativeMCPConnectionsUITests/testReviewedNativeProcessStartHealthStopAndRestart -parallel-testing-enabled NO test
```

Passed: 12 native model tests and 1 native UI test, zero failures (`TestResults/p3-08-prompt-ui.log`). Three new model regressions cover separate prompt review/empty results/stop clearing, denial with fixed diagnostics, and late completion after Stop. The UI test exercises two real synthetic process cycles with tool and prompt discovery, their distinct approval buttons, visible prompt title and argument description, health and Stop. Exported prompt screenshot `TestResults/p3-08-prompt-ui-images/EB1A0CC3-F871-45D2-A117-9D0D37B6BABB.png` was visually inspected; the complete prompt card and fixed controls are readable.

Normal signed Mac build passed using the standard Mac build command (`TestResults/p3-08-prompt-ui-build.log`). Documentation/diff checks pass. This Mac-only UI adds no Simulator or physical-display coverage. Resource discovery, prompt retrieval, tool invocation and remaining manager/transport requirements remain outstanding: 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Native resource browsing

The connection screen now lists scoped redacted resource metadata after its independent discovery approval. Resource cards display title/name, opaque URI, description, MIME type and byte-size text; they offer no URI-opening or content-reading action. Empty results have a dedicated state. Stop/failure clear the catalog, and late results cannot restore stopped state. Tool, prompt and resource discovery buttons share a compact fixed row, retaining a larger scroll area for descriptions.

Validation on macOS 26.5.2 / Xcode 26.0:

```sh
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-08-resource-ui.xcresult -only-testing:AgentDeskTests/NativeMCPLifecycleModelTests -only-testing:AgentDeskUITests/NativeMCPConnectionsUITests/testReviewedNativeProcessStartHealthStopAndRestart -parallel-testing-enabled NO test
```

All 15 native model tests passed. The first UI attempt ended with a macOS application-activation failure (app remained Running Background), before entering the feature flow (`TestResults/p3-08-resource-ui.log`). After confirming that run was terminal, selecting the exact built app through native UI automation and raising its window, the focused UI test passed with result bundle `TestResults/p3-08-resource-ui-retry.xcresult` and log `TestResults/p3-08-resource-ui-retry.log`. The retry used the same command with only the UI test selected; no production source changed between runs.

The real synthetic process test performs two start/discovery/stop cycles across tools, prompts and resources, verifies each independent approval, checks resource title and byte-size text, and scrolls the card into view. New model regressions cover independent resource review, empty results, denial without raw errors, and late completion after Stop. Exported screenshot `TestResults/p3-08-resource-ui-images/222406B6-B246-469F-9AE2-10E5083EE0A6.png` was visually inspected; the full resource card and fixed controls are visible. Normal signed Mac build passed (`TestResults/p3-08-resource-ui-build.log`). Documentation/diff checks pass. No new iPhone or physical-display coverage is claimed for this Mac-only UI.

Resource reading/templates, prompt retrieval, tool invocation and remaining lifecycle/manager work remain outstanding: 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Native resource content reading

Each discovered resource now has a Read Content action using its opaque runtime selection. The model prepares the exact read, exposes a separate approval button, then displays redacted plain text and returned-part metadata within the selected resource card. Binary parts explicitly show their byte count with preview unavailable. Content is not interpreted as Markdown, opened as a URL or applied as instructions. The model verifies returned resource, connection, environment and project identity. Refresh, failure and stop clear content; late completions cannot restore a stopped view.

Validation on macOS 26.5.2 / Xcode 26.0:

- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-08-resource-content-ui.xcresult -only-testing:AgentDeskTests/NativeMCPLifecycleModelTests -only-testing:AgentDeskUITests/NativeMCPConnectionsUITests/testReviewedNativeProcessStartHealthStopAndRestart -parallel-testing-enabled NO test`: 18 model tests and 1 native UI test passed (`TestResults/p3-08-resource-content-ui.log`). New model regressions cover independent approval, unknown selection, empty content, refresh clearing, denial without raw errors and late completion after stop. The real synthetic-process UI test reads text and binary parts after separate approval in two start/stop cycles; it verifies no content before approval and visible text afterward.
- Normal signed Mac build passed with the standard build command (`TestResults/p3-08-resource-content-build.log`). Exported UI screenshot `TestResults/p3-08-resource-content-images/19BEE1EE-A48A-49A3-BF77-536679094670.png` was visually inspected: resource content, binary limitation and persistent controls are readable and reachable. No new iPhone or physical multi-display coverage is claimed for this Mac-only surface.

Binary previews/export, resource templates, prompt retrieval, tool invocation and remaining MCP lifecycle/manager requirements remain outstanding. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.

## Native template browsing

The implementation adds separate template discovery review, redacted template cards and a two-row control area. Model regressions cover separate approval, empty catalog, denial and late completion after stop. The live synthetic UI fixture/test now checks template discovery after resource reading in two connection lifetimes.

Validation on macOS 26.5.2 / Xcode 26.0:

- `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-08-template-ui.xcresult -only-testing:AgentDeskTests/NativeMCPLifecycleModelTests -only-testing:AgentDeskUITests/NativeMCPConnectionsUITests/testReviewedNativeProcessStartHealthStopAndRestart -parallel-testing-enabled NO test`: 21 native model tests passed; the UI test failed at application activation before feature interaction (`TestResults/p3-08-template-ui.log`). Xcode reported Running Background. The completed process exited 65.
- Selecting the exact built app through computer use confirmed the Mac is locked and automatic unlock is unavailable. The user was asked to unlock it manually. Do not count this as UI feature coverage or restart tests until an unlocked desktop is available.
- Normal signed Mac build passed (`TestResults/p3-08-template-ui-build.log`). Documentation/diff checks pass. No Simulator coverage is claimed for this Mac-only change.

After the desktop became available, the exact built app was raised and only the UI test was rerun with the same test command, omitting the model-test selector and using `TestResults/p3-08-template-ui-retry.xcresult`. The native UI test passed both connection cycles (`TestResults/p3-08-template-ui-retry.log`). No source changes were made between the failed activation and passing retry. Exported screenshot `TestResults/p3-08-template-ui-images/9C16D5D2-6D0F-4789-B79A-B3644E2ED234.png` was visually inspected: template metadata and both control rows are visible and readable. The desktop lock no longer blocks this task.

Template grammar/expansion, prompt retrieval, tool invocation and the remaining MCP manager/lifecycle requirements remain outstanding. Counts remain 52 complete, 11 Phase 3 tasks plus Phases 4–6 remaining.
