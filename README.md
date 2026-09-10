# AgentDesk

A local-first, native Apple platform for engineering agents, QA workflows, project knowledge, and execution review. The Mac executes; an iPhone companion monitors and controls explicitly permitted operations over the local network.

**Status:** Phase 1 native Mac foundation passes acceptance on `codex/native-foundation`. The Mac creates, renames and reopens local workspaces and projects. Project agent templates, instruction editing and immutable revisions are implemented, alongside scoped configuration, SQLite run storage, persisted run lifecycle/events, native Keychain support, Codex Settings through a signed Mac helper, an internal read-only Codex execution adapter, a durable policy/approval gate, and immutable environment settings with effective configuration and output-schema validation, and native versioned skill editing with pinned agent references. Native validation is recorded per task. Phases 2–6 remain pending; the iPhone is still an unpaired companion shell. Personal GitHub push succeeds. See the [implementation tasks](Docs/Development/tasks.md).

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

## Native foundation

Open `AgentDesk.xcodeproj` and select the shared `AgentDesk` scheme. It includes app, unit-test and UI-test targets. The Mac has an initial workspace/run/connection sidebar; the iPhone shows that no Mac is connected. On Mac, choose **Create Workspace**, name it, then choose **Create Project**. Names and selected workspace persist across launches. Rename controls preserve identities and project membership. Each project has an **Agents** panel for templates, editable instructions and saved versions. **Shared Instructions** edits guidance at workspace or project scope; **Review Instructions** shows the exact composed files, versions and fingerprints. **Skills** creates reusable instruction bundles and example/script attachments; an agent’s **Skills** tab pins exact versions for preview. Mac **Settings → AI · Codex** checks the installed CLI and manages its supported account flow. A read-only provider has passed a real synthetic CLI task; stored configuration now resolves environment limits and validates structured Codex results. Redaction, persisted evidence/Git capture, policy-gated run coordination and the signed native execution service are implemented. Repository registration and current-context setup services are also tested. The native **Setup** screens select repositories and edit versioned execution settings, including complete advanced JSON. Folder access and saved settings survive relaunch. The project’s **Run** console supports current-context review, explicit preparation/approval, live state, cancellation and saved evidence/diff inspection. **Browse Saved Runs** needs no Codex login or new execution. Mac console acceptance and primary iPhone regressions pass; see [the record](Docs/Development/p1-13c2-validation.md). Secure pairing remains planned.

Local Swift packages are under `Packages/AgentDeskCore`, `Packages/AgentDeskDesign`, `Packages/AgentDeskPersistence`, `Packages/AgentDeskSecurity` and `Packages/AgentDeskRuntime`. The app uses Swift 6, targeting macOS 15 and iOS 18 or newer. Native Mac and iPhone 16 Pro/iOS 26 unit/integration suites pass. Current acceptance includes 351 Mac unit/integration tests, eight affected native UI scenarios, 228 iPhone tests and a separate real Codex critical-slice run, as detailed in [Phase 1 acceptance](Docs/Development/p1-15-acceptance.md). Broader device/OS coverage is reserved for final project acceptance.

```sh
python3 Scripts/validate-documentation.py
swift test --package-path Packages/AgentDeskCore
```

Use the shared Xcode scheme for native validation: `xcodebuild -project AgentDesk.xcodeproj -scheme AgentDesk -destination 'platform=macOS' test`. The old manual Core/Design compiler checker has been retired because it does not build the app's current package graph. Its original evidence remains in [foundation validation](Docs/Development/p1-01-validation.md). Current acceptance and the explicit opt-in real Codex scenario are recorded in [Phase 1 acceptance](Docs/Development/p1-15-acceptance.md).

## Development workflow

Complete one task at a time: implement, exercise the behavior, add unit/regression tests, run relevant checks (including native iPhone Simulator coverage for shared/mobile changes), review the diff, and make a separate commit. Tests belong with the change they validate.

The first application milestone is the Phase 1 critical path: create a workspace, project, and agent; edit instructions; execute through Codex CLI; watch live steps; inspect results and file changes. Secure LAN/mobile execution follows the staged roadmap; mobile compilation and simulator validation start when the native targets exist.

On Mac, **Get Started** checks local setup and opens recovery/configuration screens without starting a run. **Command-K** searches commands by project/workspace context. The menu bar shows persisted counts for open run sessions, and **Runs** opens existing consoles across windows or scoped project history. Editors adapt to compact and large logical window sizes; physical monitor acceptance is still pending.

Native project Requirements now supports reviewed immutable versions, draft/active/retired status, environment selection, structured JSON editing and historical viewing. See [requirement documentation](Docs/Architecture/requirements.md) and [P2-02 validation](Docs/Development/p2-02-validation.md). Deterministic typed requirement validation is implemented with scoped observations and exact version/fingerprint results; see [validation](Docs/Development/p2-03-validation.md). Reviewed traceability services retain creation versions, resolve current behavior for reruns and report stale links across tests, bugs, docs and workflows; see [traceability validation](Docs/Development/p2-04-validation.md). Native relationship management remains upcoming.
