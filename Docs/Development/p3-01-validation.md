# P3-01 — Scoped plugin configuration and lifecycle

Implemented foundation, 2026-09-11. This task supplies real local configuration storage and transport lifecycle ownership. It does not implement a live Jira adapter, capability dispatch, authentication UI or a connected native plugin screen; those remain P3-02 through P3-05.

## Behavior

AgentDeskPlugins provides typed Jira instance configuration: schema version 1, HTTPS without embedded user/password/query/fragment, and a Keychain reference bound to the exact workspace, project and environment. Decoding invokes the same validation as construction. Configuration contains no SecretValue and never proves authentication or health.

The catalog creates a scoped generic configuration store using its existing descriptor-based filesystem boundary. Every operation checks catalog membership. Saves use optimistic revision checks, publish immutable human-readable JSON, then atomically update the current pointer. Orphan revisions are retained and skipped by later numbering. Current and explicit historical reads verify identity, scope and revision. Malformed pointers are preserved and rejected, and symlink reads are rejected.

The lifecycle owns opening tasks and sessions. Replacement/disconnect cancels opening work and awaits cleanup; a cleanup chain prevents reentrant calls from bypassing an earlier close. Generation checks reject stale completion. Caller cancellation closes late sessions. Connection timeout defaults to 30 seconds, accepts positive durations up to 120 seconds, and cancels transport work. Authentication expiry is distinct from generic failure. Discovered normalized issue/comment/attachment capabilities exist only while connected and grant no authority.

Adapters must honor cancellation, clean partially acquired resources on failure and provide idempotent close that finishes cleanup. Timeout bounds the connection attempt after prior cleanup, but cannot forcibly terminate an uncooperative adapter; cleanup is awaited rather than abandoned. Real adapters must validate this contract with their own integration tests. The local administrative store and lifecycle are not exposed as agent or mobile execution interfaces.

## Validation

Mac environment: arm64 macOS 26.5.2 (25F84), Xcode 26.0 (17A324). Primary Simulator: iPhone 16 Pro, iOS 26.0 (23A343), UUID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.

| Evidence under ignored TestResults/p3-01 | Result and scope |
| --- | --- |
| plugins-final.log | 15 package tests passed on Mac: decoding/scope/endpoint validation, immutable storage/reopen/stale edits, orphan recovery, symlink and pointer rejection, disconnect, cancellation, late completion, cleanup ordering, timeout and authentication states |
| core.log | 196 existing Core tests passed after adding the catalog store factory |
| mac.xcresult / mac.log | 518 native Mac app tests passed; validates shared Core integration, not native plugin UI |
| iphone.xcresult / iphone.log | 337 native iPhone app tests passed; shared Core integration |
| plugin-iphone.xcresult / plugin-iphone.log | All 15 plugin-package tests passed directly in the primary iPhone Simulator |

No live Jira/company connection or external mutation was performed. Native app tests do not link the plugin package; the direct package Simulator run covers that new code separately. Physical monitor and wider device/runtime matrices remain final-product acceptance per user direction.

Initial sandboxed SwiftPM execution failed because the compiler cache was inaccessible. The approved retry succeeded. Adding the Core source also encountered a stale SwiftPM dependency source inventory; refreshing the generated package build plan with `swift package --package-path Packages/AgentDeskPlugins clean` resolved it. Neither failed attempt is counted as passing validation.

## Commands

From the repository root:

```sh
swift test --package-path Packages/AgentDeskPlugins
swift test --package-path Packages/AgentDeskCore
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac -resultBundlePath TestResults/p3-01/mac.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath TestResults/p1-08b/FilteredIPhone -resultBundlePath TestResults/p3-01/iphone.xcresult -only-testing:AgentDeskTests -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```

From Packages/AgentDeskPlugins:

```sh
xcodebuild -scheme AgentDeskPlugins -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' -derivedDataPath ../../TestResults/p3-01/PluginIPhone -resultBundlePath ../../TestResults/p3-01/plugin-iphone.xcresult -parallel-testing-enabled NO test
```

Use fresh result-bundle names for repetitions. Documentation integrity, section coverage, local links, ignore rules and whitespace checks passed.
