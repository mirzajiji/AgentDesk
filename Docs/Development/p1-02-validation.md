# P1-02 scoped identities and filesystem validation

Date: 2026-09-09. Starting commit: `7b369f5`; branch: `codex/native-foundation`. Xcode 26.0 (17A324), Swift 6.2, macOS 26.5.2 (25F84), arm64 MacBook Pro.

## Delivered behavior

UUID-backed workspace, project, environment, run and agent identities serialize as canonical strings. A project scope carries both parent and child identities. Portable workspace paths validate on construction and decoding. Descriptor-bound reads reject foreign workspace references, traversal/absolute paths, symlink and hardlink access, directories and special files. They enforce bounded reads and cancellation and retain their original root when its pathname is replaced.

The trusted container alone is canonicalized with POSIX `realpath`. An initial Foundation-based implementation retained a macOS `/var` alias and failed seven fixture reads; this was corrected before the final runs. Storage scope does not prove project membership or grant runtime authorization. Creation and writes remain P1-03 work.

## Commands and results

```sh
swift test --package-path Packages/AgentDeskCore
python3 -B -m unittest discover -s Scripts/tests -v
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=macOS' \
  -derivedDataPath TestResults/p1-01/NativeMac \
  -resultBundlePath TestResults/p1-02/mac-final.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk \
  -destination 'platform=iOS Simulator,id=C1729D51-EE0A-4A77-80E9-9CE5A7EDA6FE' \
  -derivedDataPath TestResults/p1-01/NativeiPhonePrimary \
  -resultBundlePath TestResults/p1-02/iphone-final.xcresult \
  -parallel-testing-enabled NO -only-testing:AgentDeskTests test
```

All commands pass. SwiftPM: **21 tests**. Native Mac: **22 tests**. Native iPhone 16 Pro, iOS 26.0 (23A343): **22 tests**. Zero failures. Tooling: **3 tests**, including accurate expanded-suite counts and stale-success rejection. Fixtures are isolated temporary directories with synthetic content; they include nested/chunked/empty files, missing files, invalid limits, cross-workspace links, FIFO rejection and pre-cancelled reads.

Logs and native result bundles remain ignored under `TestResults/p1-02/`. No UI behavior changed, so P1-01 native UI coverage remains applicable; this task builds both apps and executes native unit tests on both. The broader device matrix remains deferred by the user until full-project acceptance.

`python3 Scripts/validate-documentation.py` and `git diff --check` pass before commit. Review excludes Xcode's unrelated project-file ordering changes and all runtime/test output.
