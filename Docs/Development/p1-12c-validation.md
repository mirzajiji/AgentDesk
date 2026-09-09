# P1-12c Git snapshots and sanitized change previews

Date: 2026-09-10. Starting commit `951adfb`; branch `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, macOS 26.5.2 (25F84), arm64; Apple Git 2.50.1 (Apple Git-155). Native iPhone tests ran on **AgentDesk iPhone 16 Pro**, **iOS 26.0 (23A343)**, ID `C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE`. Broader device/minimum-runtime validation remains deferred until full-project acceptance.

## Implemented and exercised

The internal Mac capture actor binds an authorized repository root to the run's redactor, freezes a dirty baseline and produces subsequent observed comparisons. It reads NUL-delimited porcelain-v2 status, checks hidden index flags, validates local configuration without following includes and reads immutable Git blobs plus scoped working files. It preserves the index and all existing working edits. No reset, clean, commit, shell or network operation is exposed.

The source text is redacted before deterministic line comparison, preserving multiline secret boundaries. Previews separate HEAD-to-index, index-to-working-tree and baseline-to-working-tree differences; paths use unambiguous JSON escaping. Metadata identifies preexisting, newly changed and no-longer-listed paths without inferring authorship or a reason for disappearance. Restored tracked files and removed untracked files retain their baseline comparison. Snapshot/diff wrappers publish through the evidence store and survive reopening with correct classification.

Two matching observations and Git metadata checks detect unstable capture. Replaced roots, changed branch/HEAD/configuration, malformed paths/output, dangerous config, links in metadata, hidden index flags and unsupported repository formats fail explicitly. Binary, large, symlink and submodule content has clear preview limitations. See the [repository contract](../Architecture/repositories.md) for exact supported formats, limits and the distinction between an observation window and an atomic filesystem snapshot.

## Accepted results

- **82 Runtime tests pass**, including five new shared parser/config/diff tests and nine real Mac Git capture tests. Coverage includes initial/unborn repositories, staged versus working bytes, additions/modifications/deletions/renames, whitespace/newline filenames, unchanged preexisting edits, restoration/removal, source and path secret masking, record publication/reopening, binary/large/symlink states, hardlink rejection, dangerous filter/diff/fsmonitor settings, includes/alternates/hidden index flags, replaced roots, changed branches, bounds and cancellation. Existing transport tests continue to cover subprocess timeout and cleanup.
- **252 affected native Mac unit/integration tests pass**, including all nine Git capture tests inside the main app's sandbox. The complete accepted batch excludes the two unchanged Keychain integration tests described below. The earlier focused nine-test native Git retry also passed and is not added again to the distinct test count.
- **200 native iPhone unit/integration tests pass** on the primary Simulator. The five shared parser/config/diff tests execute there; Git subprocess execution remains Mac-only.
- The **normal signed Mac build passes**. App/helper signatures verify. The main app retains App Sandbox and user-selected read-only file access; the previously approved Codex helper remains unchanged without App Sandbox. Git executes directly inside the main app's existing sandbox, with no new helper authority or entitlement changes.
- Documentation integrity, 159-section ownership/coverage, links, ignore rules and staged whitespace checks pass. Preexisting Xcode formatting/normalization, personal scheme metadata and historical handoff wording remain excluded.

## Failed attempts and unavailable checks

The initial Swift compile hit an overly complex optional-count expression and a test property that collided with XCTest's inherited `hash`; both were corrected. The first executable suite exposed Foundation retaining macOS's `/var` alias where `realpath` returns `/private/var`. The root validator now canonicalizes trusted ancestors while still rejecting a selected-directory link and pinning device/inode. All final root-replacement and link-denial tests pass.

The initial native batch ran 254 unit tests with 11 failures: nine Git fixture failures plus two Keychain failures. Sanitized fixture diagnostics established that `/usr/bin/git` invokes `xcrun`, which explicitly refuses App Sandbox. The adapter and fixtures now locate Apple's actual Git binary under standard Xcode/Command Line Tools installations. The final native Git tests pass under the unchanged sandbox.

The two unchanged Mac Keychain integration tests returned `errSecInteractionNotAllowed` (`-25308`). The unchanged Settings UI regression also failed because XCTest could not activate the app, which remained running in the background. They had passed in P1-12b but were unavailable in this session; they are **not counted as passing for P1-12c**. The accepted native batch explicitly skips only `KeychainIntegrationTests` and does not claim UI acceptance. This task changes neither Keychain behavior nor Settings/UI code. Re-run those checks when interactive native access is available, and before accepting later UI/Keychain changes. No normal UI launch is claimed for this task.

## Commands and evidence

Generated logs and bundles remain ignored under `TestResults/p1-12c/`. Final accepted records are `runtime-final.log`, `mac-unit-final.log/.xcresult`, `iphone-final.log/.xcresult` and `normal-mac.log`. `mac-git-direct.log/.xcresult` is the focused native Git acceptance. Earlier failures remain in `capture-build.log`, `parsing-tests-fixed.log`, `capture-tests-fixed.log`, `mac-accepted.log/.xcresult` and `mac-git-diagnostic.log/.xcresult`.

```sh
swift test --package-path Packages/AgentDeskRuntime \
  --scratch-path TestResults/p1-12c/RuntimeBuild
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-12c/mac-unit-final.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -skip-testing:AgentDeskTests/KeychainIntegrationTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-08b/FilteredIPhone \
  -resultBundlePath TestResults/p1-12c/iphone-final.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests \
  -test-timeouts-enabled YES -maximum-test-execution-time-allowance 30 test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' -derivedDataPath TestResults/p1-08b/NormalMac build
python3 Scripts/validate-documentation.py
git diff --check
```

Native Git diagnostics used only synthetic temporary repositories and redacted fixture stderr. The actual source repository was not used as a capture fixture. The main app can use the installed Apple Git binary directly; missing standard installations remain a visible unavailable-tool error. Native registration, coordinator wiring, richer binary/worktree support and Git mutations remain subsequent work.
