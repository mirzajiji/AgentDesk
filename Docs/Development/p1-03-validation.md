# P1-03 workspace and project management validation

Date: 2026-09-09. Starting commit: `c496060`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2. Native MacBook Pro arm64, macOS 26.5.2 (25F84). Primary Simulator: iPhone 16 Pro, iOS 26.0 (23A343), ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`.

## Delivered behavior

The Mac now creates, lists, renames and reopens workspaces and projects through native forms. Workspace selection persists. Switching workspace clears previous project content immediately. Duplicate/invalid names produce actionable errors; cancellation preserves existing data. Configuration uses readable schema-versioned JSON, stable UUID directories, validated parent membership, private staging, atomic publication and a catalog lock. The existing isolated read boundary is shared with the new configuration directory implementation.

Synthetic tests cover reopen/rename, normalized duplicates, invalid names, malformed and unsupported schemas, wrong identities, copied projects with foreign membership, symlink and hardlink rejection, write collisions, cancellation, abandoned staging and concurrent catalog creation. Model tests cover selection restoration, clearing project content on failed selection, and rename identity preservation. No delete/archive or repository registration is claimed.

## Commands and final results

```sh
swift test --package-path Packages/AgentDeskCore
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' \
  -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-03/mac-final.xcresult \
  -parallel-testing-enabled NO test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-01/NativeiPhonePrimary \
  -resultBundlePath TestResults/p1-03/iphone-first.xcresult \
  -parallel-testing-enabled NO test
python3 Scripts/validate-documentation.py
git diff --check
```

**PASS:** 31 SwiftPM tests; Mac 35 unit and 6 UI executions; iPhone 32 unit and 7 UI executions. Both native builds, test runs and app launches succeed with zero final failures. UI counts include launch tests across appearance/orientation configurations. The iPhone keeps its truthful unpaired state; this change adds no mobile administrative capability. Broader device coverage remains deferred by the user.

Mac UI acceptance creates a workspace and project, renames the project, creates and switches to a second workspace, verifies the first project's absence there, returns to the first workspace, relaunches the app and verifies its persisted selection and project. Separate UI coverage checks duplicate and invalid name errors and cancellation. The app-only screenshot after relaunch was visually inspected: workspace context, project name and controls are readable.

An initial Mac compile found a missing Combine import; it was corrected. The first executable UI run found a parent-row accessibility identifier overriding the Rename button identifier. The row-wide identifier was removed and the final full Mac suite passes. Package/storage code did not change after the passing iPhone suite; the final UI fix and Combine import are Mac-only.

All logs, screenshots and result bundles remain ignored under `TestResults/p1-03/`. Test launches use isolated UUID storage and preferences. Unrelated Xcode project-file ordering changes are excluded from this task's commit. See [workspace storage guarantees and limitations](../Architecture/workspaces.md).
