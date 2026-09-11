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
