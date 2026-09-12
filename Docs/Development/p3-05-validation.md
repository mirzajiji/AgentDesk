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


## Native reset

Added Reset with a native confirmation describing its exact effect: remove the local grant, clear the credential reference and disable the connection while preserving site, environment and immutable history. It shares authentication ownership and stale-row validation with logout. Credential deletion precedes publication; a later cancellation/stale revision can leave an empty old reference, so failure guidance explicitly reports possible partial cleanup instead of claiming success.

`native-reset-build.log`: normal Mac build passed. Added model tests for successful reset, deletion failure and a concurrent configuration update between deletion and publication, including historical-version preservation. The compact layout regression now includes the sixth action. Native results are `native-reset.xcresult` / `native-reset.log` when complete. No live account was reset.


The first native run passed seven model tests but both UI scenarios failed to interact with the window; the AX snapshot marked the app disabled. A session check reported an unlocked console. Retrying unchanged code in `native-reset-ui-retry.xcresult` passed both UI scenarios. No root cause beyond the observed interaction failure is claimed. The direct reset confirmation test is now running in `native-reset-confirmation.xcresult`: cancel must retain v1; confirmation must publish disabled v2 and remove credential-only controls, using the reference-only synthetic fixture.


The first direct confirmation test failed because Cancel matched both the Touch Bar and sheet. Scoping Cancel and Reset Connection to the sheet fixed the selector. `native-reset-confirmation-fixed.xcresult` passed: cancelling preserved v1, confirming published disabled v2 and removed credential-only controls. Seven native model tests, the two unchanged UI regressions on retry, and this direct confirmation test passed on macOS 26.5.2 / Xcode 26.0. Commands used the AgentDesk project/scheme, native Mac destination, NativeMac derived data and disabled parallel testing with the named test selectors. Documentation and diff checks passed. No real grant existed in the fixture; the deletion-failure and concurrent-publication scenarios use injected model services. Mac-only change, no new iPhone coverage claimed. Full P3-05/live-account acceptance remains open.


## Persisted connection permissions

Jira configuration now accepts an optional scoped PluginPermissions document. Connection/project/environment mismatches are rejected during construction and decoding. Legacy absence resolves deterministically to deny-all permissions. Native configuration edits, credential reservation and reset preserve any existing permission document. Native permission editing/review and runtime retrieval of these persisted documents are not wired yet.

`swift test --package-path Packages/AgentDeskPlugins --filter JiraStoredPermissionsTests` initially failed because a throwing assertion omitted `try` (`stored-permissions.log`); corrected run passed (`stored-permissions-fixed.log`). The test covers legacy deny defaults, deterministic resolution, round-trip encoding and foreign identity rejection. Full persistence/native checks and the task commit remain pending.


The persistence extension passed two focused host tests (`stored-permissions-history.log`), including reopening authoritative files, historical deny preservation and stale-save rejection. Added the native model save path for validated rules, preserving connection identity, site, credential reference and enabled state while publishing a new configuration version. `permissions-model-build.log` passed the normal Mac build. Native editor/review, model regression coverage and runtime retrieval remain in progress; no permission component commit or end-to-end enforcement claim is made yet.


Added the native Permissions editor with deny/approval/allow choices and a separate immutable selection review before saving. It preserves connection identity and uses optimistic configuration revisions. `permissions-editor-build.log` passed the normal Mac build. The native review/relaunch scenario is running in `permissions-editor.xcresult` / `permissions-editor.log`; final UI and broader validation remain pending. Persisted permissions still require runtime lookup integration before end-to-end enforcement can be claimed.


`permissions-editor.xcresult` passed the native Mac UI scenario (one test, zero failures): Save is unavailable before review, the review shows deny → approval, saving publishes v2, and the selected approval rule survives app relaunch. This establishes editor persistence, not runtime use of the saved rule. Visual review, model regressions, runtime integration and Mac/iPhone shared checks remain before committing this task.


Added `PluginPolicySession.openStored` for trusted runtime adapters to load current persisted configuration/permissions and repeat that lookup during policy review/dispatch. Its preparation closure binds an exact stable action to the supplied current record. `stored-policy-runtime-build.log` passed the two existing policy-session tests; `stored-policy-runtime-tests.log` passed the new persisted-rule integration test. That test uses real scoped configuration files and SQLite approvals with a synthetic effect: deny/approval prevent dispatch, allow permits it, and a saved change invalidates an already approved action. No Jira HTTP was sent. Existing callers are not automatically migrated; full native operation routing and broader acceptance still remain.


Full Plugins host regression passed 85 tests (`permissions-plugins-full.log`). `permissions-native.xcresult` passed nine native model tests and three UI tests, including ordinary edits/reset preserving permissions, stale permission save rejection, compact lifecycle/reset and permission review/relaunch. The initial permission screenshot was visually inspected; its internal capability labels were then replaced with readable names. The final label UI check is `permissions-readable-ui.xcresult`. Full Runtime regression, native shared iPhone validation and final builds remain pending before commit.

The readable-label native UI rerun passed (one test, zero failures). Remaining pre-commit checks are unchanged.


Full Runtime host regression passed 166 tests (`permissions-runtime-full.log`). Native iPhone Plugins regression passed all 85 tests (`permissions-plugins-iphone.xcresult`) on iPhone 16 Pro / iOS 26.0. Runtime Simulator coverage is running in `permissions-runtime-iphone.xcresult`; final application builds and commit review remain pending. All runs use synthetic fixtures and the existing scoped local test stores.


Final permission component checks passed: 85 Plugins and 166 Runtime host tests; 85 Plugins and 85 Runtime tests on iPhone 16 Pro / iOS 26.0; nine native Mac model tests and three UI regressions, plus the final readable-label UI rerun. Both normal app builds passed (`permissions-app-mac.log`, `permissions-app-iphone.log`). Native commands used Xcode 26.0, macOS 26.5.2, the documented AgentDesk/AgentDeskPlugins/AgentDeskRuntime schemes, native Mac or primary Simulator UUID, existing derived-data directories and disabled parallel testing. Documentation integrity/link and staged diff checks passed.

This checkpoint delivers persisted permission documents, reviewed native editing and a runtime factory backed by authoritative stored rules. It does not claim migration of every manually constructed runtime session, full native Jira execution, live authentication or completion of P3-05. Unrelated Xcode normalization and historical handoff edits remain outside the commit. No real credentials, company data or live Jira traffic entered the tests.


## Exact stored configuration binding

Review found the stored-policy factory verified IDs/revisions/permissions but relied on the adapter to use the complete saved configuration. Prepared actions now expose a canonical configuration fingerprint, and the factory compares it with the authoritative record before opening the policy session. Disabled stored configurations are rejected before invoking the adapter builder.

`swift test --package-path Packages/AgentDeskRuntime --filter StoredPluginPolicySessionTests` passed (`stored-config-binding.log`). The regression supplies a different site with matching connection/project/environment IDs and revision, and confirms rejection. Broader plugin/native checks and the focused fix commit remain pending. No external request was made.


Final binding checks passed: one focused runtime integration test on the Mac host and on iPhone 16 Pro / iOS 26.0 (`stored-config-binding.log`, `exact-binding-iphone.xcresult`), all 85 Plugins host tests (`exact-binding-plugins.log`), and normal Mac/iPhone application builds (`exact-binding-app-mac.log`, `exact-binding-app-iphone.log`). The Simulator run used AgentDeskRuntime with `-only-testing:AgentDeskRuntimeTests/StoredPluginPolicySessionTests`, the primary UUID and RuntimeIPhone derived data. Builds used the existing AgentDesk project/scheme and documented destinations. Xcode 26.0 / macOS 26.5.2. Diff and documentation checks passed. No UI behavior changed and no additional UI acceptance is claimed. Full native operation routing remains unfinished.
