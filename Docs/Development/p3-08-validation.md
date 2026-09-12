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
