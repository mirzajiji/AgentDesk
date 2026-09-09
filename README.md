# AgentDesk

A local-first, native Apple platform for engineering agents, QA workflows, project knowledge, and execution review. The Mac executes; an iPhone companion monitors and controls explicitly permitted operations over the local network.

**Status:** Phase 1 is underway on `codex/native-foundation`. The Mac creates, renames and reopens local workspaces and projects. Project agent templates, instruction editing and immutable revisions are implemented, alongside scoped configuration, SQLite run storage and native Keychain support. Native validation is recorded per task. Personal GitHub push succeeds. See the [implementation tasks](Docs/Development/tasks.md).

## Product and development references

- [Supplied final architecture — all 159 sections](Docs/Architecture/final-architecture.txt)
- [Complete subsystem documentation index](Docs/Architecture/README.md)
- [Requirement-to-document coverage for all 159 sections](Docs/Architecture/coverage.md)
- [Development rules and personal GitHub identity](AGENTS.md)
- [Repository setup and outstanding access requirements](Docs/Development/repository-setup.md)
- [Commit-sized implementation tasks](Docs/Development/tasks.md)
- [macOS and iPhone testing policy](Docs/Development/testing.md)
- [Bootstrap validation record](Docs/Development/bootstrap-validation.md)
- [Continuation context for the updated local project](Docs/Development/continue-in-updated-project.md)

Swift, SwiftUI, Swift Package Manager, SQLite, macOS Keychain, and the officially authenticated Codex CLI form the foundation. The application has no OpenAI API or Agents SDK dependency.

Configuration stays human-readable; operational data stays local. Workspace and project isolation is enforced in code. Company data, credentials, and generated evidence must not be committed to this source repository.

## Native foundation in progress

Open `AgentDesk.xcodeproj` and select the shared `AgentDesk` scheme. It includes app, unit-test and UI-test targets. The Mac has an initial workspace/run/connection sidebar; the iPhone shows that no Mac is connected. On Mac, choose **Create Workspace**, name it, then choose **Create Project**. Names and selected workspace persist across launches. Rename controls preserve identities and project membership. Each project has an **Agents** panel for templates, editable instructions and saved versions. **Shared Instructions** edits guidance at workspace or project scope; **Review Instructions** shows the exact composed files, versions and fingerprints. Codex execution and secure pairing are not implemented yet.

Local Swift packages are under `Packages/AgentDeskCore`, `Packages/AgentDeskDesign`, `Packages/AgentDeskPersistence` and `Packages/AgentDeskSecurity`. The app uses Swift 6, targeting macOS 15 and iOS 18 or newer. Native Mac and iPhone 16 Pro/iOS 26 unit and UI suites pass. Broader device/OS coverage is reserved for final project acceptance.

```sh
python3 Scripts/validate-documentation.py
swift test --package-path Packages/AgentDeskCore
```

Supplementary source checks and host XCTest execution are available with `python3 Scripts/check-foundation-sources.py`; they do not replace Xcode build or Simulator testing. Exact commands and current limitations are in [validation](Docs/Development/p1-01-validation.md).

## Development workflow

Complete one task at a time: implement, exercise the behavior, add unit/regression tests, run relevant checks (including native iPhone Simulator coverage for shared/mobile changes), review the diff, and make a separate commit. Tests belong with the change they validate.

The first application milestone is the Phase 1 critical path: create a workspace, project, and agent; edit instructions; execute through Codex CLI; watch live steps; inspect results and file changes. Secure LAN/mobile execution follows the staged roadmap; mobile compilation and simulator validation start when the native targets exist.
