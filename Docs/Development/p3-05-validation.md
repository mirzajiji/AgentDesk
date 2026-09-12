# P3-05 native plugin setup and diagnostics

Status: in progress. The configuration-management component is implemented; authentication, real diagnostics, permissions review and the remaining lifecycle are not complete.

## Implemented configuration component

- The Mac Connections destination selects workspace/project and opens persisted Jira configurations. Empty projects direct the user to create a project; projects without environments direct the user to Setup.
- Core configuration storage lists only published heads, supports environment filtering and UUID-keyset pagination, validates scope and records under the catalog lock, and bounds pages to 100 records and the directory inventory to 10,000 entries. Refresh starts a new listing; this is not a snapshot across pages.
- The native model loads current configuration, ignores stale load completions after close, validates project/environment association and saves immutable revisions with the expected previous revision.
- The editor creates or edits HTTPS site-origin configurations and enabled state. It preserves existing environment identity and credential references; changing a credential-bearing site requires the future disconnect flow. No secret entry, OAuth request, live Jira call or authentication claim occurs here.
- The main app now directly links AgentDeskPlugins. Only that linkage change belongs in this commit; preexisting Xcode normalization and user scheme/handoff changes remain separate.

## Validation so far — 2026-09-12

Environment: Xcode 26.0, macOS 26.5.2, primary iPhone 16 Pro Simulator on iOS 26.0 (`C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`).

`swift test --package-path Packages/AgentDeskPlugins --filter PluginStorageTests` passed five tests (`TestResults/p3-04/connection-list-host.log`), including new published-head pagination, environment filtering, reopening, foreign-scope denial and invalid page-size checks.

The first native test build failed with unresolved Jira configuration symbols (`TestResults/p3-05/configuration-native.log`). The app previously used only an indirect plugin dependency while tests linked it directly. Explicit app product/framework linkage corrected this. The next run passed two new Mac model tests and the existing empty-sidebar navigation test, but the new UI test assumed the Enabled toggle was an accessibility checkbox (`configuration-native-linked.xcresult`). It was corrected to locate the native control by identifier.

The final configuration UI test passed (`configuration-ui-final.xcresult`): rejects an HTTP site, saves an enabled HTTPS configuration, relaunches, reopens it and publishes a disabled second version. Exported and visually inspected the app-window screenshot at `TestResults/p3-05/configuration-shots/05980A06-C17A-447A-BACF-D816A6F20D79.png`; selectors, actions and saved state are visible. Synthetic test data only; screenshot remains ignored.

Native app test commands use `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -parallel-testing-enabled NO test` with the `ProjectJiraConnectionsModelTests`, `NativeConnectionsUITests` and existing sidebar test selectors. The final UI rerun selected only `NativeConnectionsUITests`.

Shared iPhone package validation and final ordinary builds are recorded below when complete. P3-05 remains open for native OAuth, test/disconnect/logout/reset, permissions and health, broader lifecycle UI testing and full acceptance. P3-04 mutation and upload UI integration also remains open.

## Final checks for the configuration component

All 80 Plugins tests passed on iPhone 16 Pro / iOS 26.0 (`TestResults/p3-05/configuration-plugins-iphone.xcresult` and matching log). The command used the AgentDeskPlugins package scheme, primary Simulator UUID, existing `TestResults/p3-04/PluginsIPhone` derived-data path and disabled parallel testing. This tests shared storage and plugin code, not a mobile connection editor.

Normal Mac and iPhone app builds passed (`configuration-app-mac.log`, `configuration-app-iphone.log`) using the AgentDesk project/scheme, native Mac or primary Simulator destination, and `TestResults/p1-01/NativeMac` / `TestResults/p1-08b/FilteredIPhone` derived-data paths. The four-line direct app dependency change was separately prepared against HEAD and passed `plutil -lint`; unrelated Xcode formatting remains outside this task’s commit. Documentation integrity/link checks and diff whitespace checks passed.

This checkpoint delivers real persisted configuration management. It does not complete P3-05 or claim authenticated connections, remote diagnostics, permission editing, live Jira writes, image review, or the final multi-display matrix.

## OAuth registration binding

Before native sign-in integration, bound saved grants to the broker origin, public client ID, callback and requested access mode. The fingerprint lives in the existing scoped Keychain bundle. Refresh checks it before deleting the old token or contacting the broker. New sign-ins and rotations write the binding; legacy unbound records remain readable but require fresh sign-in before refresh.

The initial 80-test host suite passed (`oauth-registration-binding-host.log`). The added registration-mismatch test first failed to compile because its injected adapter omitted the clock argument (`oauth-registration-binding-full.log`); this fixture was corrected. All 81 host tests then passed (`oauth-registration-binding-fixed.log`). Tests cover changed origin/client/callback/access, zero HTTP requests, preservation of the original grant, legacy records, logout, and binding persistence through sign-in and rotation. The native Mac Plugins suite also passed; final native results follow below. Logs are under `TestResults/p3-05/`. No real credentials or live broker requests were used.


Final registration-binding checks: 81 Plugins tests passed on native macOS 26.5.2 and 81 on iPhone 16 Pro / iOS 26.0, with zero failures (`registration-binding-mac.xcresult`, `registration-binding-iphone.xcresult`). Commands used `xcodebuild -scheme AgentDeskPlugins -parallel-testing-enabled NO test` from the Plugins package, with native Mac or primary Simulator UUID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE` destinations and the existing PluginMac / PluginsIPhone derived-data directories. Both normal app builds passed (`registration-app-mac.log`, `registration-app-iphone.log`) with Xcode 26.0 and the AgentDesk project/scheme. Documentation and diff checks passed. This completes the registration-binding component; native sign-in and full P3-05 acceptance remain outstanding.


## Native sign-in coordination in progress

Added an injectable asynchronous configuration validator to `JiraOAuthLogin.signIn`, checked before starting OAuth and before/after saving the validated grant. Rejection after saving uses the existing independent cleanup task to remove the attempted grant. This is not an atomic transaction with configuration storage; the native coordinator still must supply scoped revision checks and manage operation ownership.

`swift test --package-path Packages/AgentDeskPlugins --filter JiraOAuthLoginTests` passed two host tests (`TestResults/p3-05/login-revalidation.log`). The added regression rejects at each of the three validation boundaries, checks browser invocation, and verifies no grant remains. Synthetic transports only. Native integration, full native validation and the task commit remain pending; no new sign-in UI or live authentication is claimed.


The native coordinator and Sign In/Cancel controls are now implemented for a publisher-provided bundle registration. It reserves a scoped reference, serializes native window ownership, checks the latest configuration/environment around OAuth, and closes transports after completion. The default build has no production registration; its Sign In button is disabled with explicit configuration guidance.

Initial native compilation exposed a Swift concurrency calling-convention mismatch between the app and package protocol witness; a small adapter resolves it. The first test build then required an explicit Security import. The first running model regression found cancellation also cancelled the list refresh, clearing the visible reserved reference. Refresh now runs in independent cleanup, with an explicit optional result type correcting a subsequent compiler inference failure. Final model/UI results follow when available. Logs: `native-login-build.log`, `native-login-model.log`, `native-login-fixed.log`, `native-login-cancellation-fixed.log`, `native-login-final.log`.


Final native sign-in component checks passed:

- `native-login-final.xcresult`: five native Mac model tests and one native Mac UI test, zero failures. The model tests cover public registration validation/read-only access, scoped reference reservation, configuration changes during login, cancellation cleanup and native ownership release. The UI test verifies the missing-registration message and disabled Sign In control alongside persisted configuration editing. Its app-window screenshot was exported and visually inspected.
- `login-plugins-mac.log`: all 82 Plugins tests passed on the Mac host using `swift test --package-path Packages/AgentDeskPlugins`.
- `login-plugins-iphone.xcresult`: all 82 Plugins tests passed on iPhone 16 Pro / iOS 26.0 using the AgentDeskPlugins package scheme, primary Simulator destination, PluginsIPhone derived-data directory and disabled parallel testing.
- `login-app-iphone.log`: ordinary iPhone app build passed. Native Mac application and test targets compiled during the successful native test run. Commands used Xcode 26.0 on macOS 26.5.2 and the previously documented project/scheme/destinations.
- Documentation integrity/link and diff whitespace checks passed.

This commits the native sign-in integration component, not full P3-05 acceptance. Synthetic model services and broker transports establish local behavior; the UI test does not open a real authorization browser or exercise a live account. Publisher registration, deployed broker, complete native authentication UI acceptance, refresh/logout/reset/test/health/permissions and broader display validation remain outstanding. No live credentials or external Jira mutation occurred.


## Local logout component

Added native Log Out for credential-bearing configurations with scoped Keychain deletion and the same ownership gate used by native sign-in. Disabled connections/retired environments remain eligible; stale configuration rows are rejected before deletion. Configuration versions and references are retained, and the UI explicitly distinguishes local grant removal from browser/Atlassian consent.

`native-logout-build.log`: normal native Mac build passed. Added a model regression covering the exact secret reference, deletion failure, disabled/retired configuration cleanup, preservation of configuration history and stale-row rejection. Native tests are recorded in `native-logout.xcresult` / `native-logout.log`; final results follow. No live account was logged out.


`native-logout.xcresult` passed six native Mac model tests and the existing connection configuration UI test, zero failures, using Xcode 26.0 on macOS 26.5.2. The UI regression verifies existing configuration navigation; it does not simulate a live authenticated account or click logout against one. Added a direct model assertion that active native sign-in ownership causes zero deletion calls; its focused result is `native-logout-ownership.xcresult`. This Mac-only change does not alter shared or iPhone code; the prior 82-test iPhone run is not claimed as new coverage.

The focused ownership regression passed (one test, zero failures). Documentation and diff checks passed. Local logout is complete as a component; live-account lifecycle acceptance and remaining P3-05 controls are still open.


## Native connection diagnostics

Added Test Connection with scoped grant restoration via the existing Jira adapter, temporary transport cleanup, shared native operation ownership, pre/post configuration validation and cancellation on project close. The model stores only typed capabilities, configuration revision and observation time; UI guidance distinguishes discovery from runtime authorization.

`native-probe-build.log`: native Mac build passed. Added model scenarios for success, expired authentication, configuration mutation during the probe, close/cancellation and invalidation on refresh. Results are in `native-probe.xcresult` / `native-probe.log` when complete. Tests inject synthetic probes; no live Jira account was contacted.


`native-probe.xcresult` passed seven native Mac model tests and one configuration UI regression, zero failures (Xcode 26.0, macOS 26.5.2). The final status label now distinguishes a checked connection from authentication-not-checked; its UI rerun is `native-probe-ui.xcresult`. All probes in model tests are synthetic. The existing UI test does not exercise a live authenticated diagnostic result. Native full-account/scope/health UI acceptance remains pending. This component changes only Mac code; no new iPhone execution is claimed.

The final native UI rerun passed (one test, zero failures). Documentation and diff checks passed. Connection testing is implemented as a component; P3-05 remains open for full lifecycle, permissions, account presentation and live acceptance.


## Native refresh integration

Added an asynchronous configuration validator to OAuth refresh. It runs before loading the grant, before consuming it, before saving the rotated grant and after saving. Early rejection preserves the original grant; rejection after consumption cannot retry the old token; rejection after saving cleans up the new grant through the existing independent deletion path.

`swift test --package-path Packages/AgentDeskPlugins --filter JiraOAuthRotationTests` passed two host tests (`TestResults/p3-05/refresh-revalidation.log`). The added regression rejects each of the four boundaries and checks exact credential-store events and remaining grant state. Synthetic broker/adapter transports only. Native refresh controls, full native validation and the focused task commit remain pending.


The native Refresh Grant control now uses the existing authentication coordinator and ownership/cancellation path. It rejects missing credential references instead of creating one, supplies configuration validation to token rotation, and reports refresh failure with fresh-sign-in guidance. `native-refresh-build.log` passed the normal Mac build. Added a native model regression for success, changed configuration during refresh and missing reference without new configuration publication. The current native run is `native-refresh.xcresult` / `native-refresh.log`; final results follow. No live broker or account was used.


Final refresh component validation passed:

- `native-refresh.xcresult`: eight native Mac model tests and one configuration UI regression, zero failures, using Xcode 26.0 on macOS 26.5.2. Model coverage includes native refresh routing, missing reference without publication, configuration changes, and existing authentication/logout/diagnostic cancellation and ownership checks. The UI regression is not a live refresh acceptance test.
- `refresh-plugins-mac.log`: all 83 host Plugins tests passed.
- `refresh-plugins-iphone.xcresult`: all 83 Plugins tests passed on iPhone 16 Pro / iOS 26.0 with the primary Simulator UUID, AgentDeskPlugins scheme and PluginsIPhone derived data.
- `native-refresh-build.log` and `refresh-app-iphone.log`: normal Mac and iPhone builds passed.
- Documentation integrity, links and diff whitespace checks passed.

The shared package commands use `swift test --package-path Packages/AgentDeskPlugins` or `xcodebuild -scheme AgentDeskPlugins -parallel-testing-enabled NO test` from the package. App checks use the AgentDesk project/scheme and previously documented Mac/primary Simulator destinations. No live broker, production registration or real grant was used. This completes the refresh component, not P3-05 or its live/full UI acceptance.


## Compact lifecycle controls

The credential-bearing row now lays actions out horizontally when space permits and vertically in narrower windows. Added a Debug-only fixture inside the existing UUID-scoped synthetic UI container that saves a credential reference without creating a Keychain value. The native layout test resizes to a compact window and checks all five actions remain within window bounds. It never invokes authentication or connection testing.

Native validation is `compact-lifecycle.xcresult` / `compact-lifecycle.log`. Final results and visual inspection follow. This layout-only task does not change shared domain behavior or claim new iPhone coverage.

Both native UI tests passed, zero failures, on macOS 26.5.2 / Xcode 26.0. The compact app-window screenshot was exported and visually inspected: all five actions remain visible in a vertical group and text stays readable. The final source adjustment only normalizes helper indentation. Documentation and diff checks passed. The requested physical-display matrix remains final acceptance work.
