# AgentDesk

A local-first, native Apple platform for engineering agents, QA workflows, project knowledge, and execution review. The Mac executes; an iPhone companion monitors and controls explicitly permitted operations over the local network.

**Status:** the original Xcode multiplatform scaffold and complete 159-section architecture are preserved here. Phase 1 implementation is beginning on `codex/native-foundation`. Source and Git writes now work after the user moved the app into this task’s workspace. GitHub DNS and local Simulator service access remain blocked. See the [current validation record](Docs/Development/updated-project-validation.md).

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

## Existing scaffold

Open `AgentDesk.xcodeproj` in Xcode. It contains the `AgentDesk`, `AgentDeskTests`, and `AgentDeskUITests` targets; the application currently displays “Hello, world!” and its tests are template tests. The template declares macOS/iOS/visionOS 26.0 and Swift language mode 5.0. P1-01 will establish the Mac+iPhone package foundation, shared schemes, deployment decisions, and meaningful tests.

Documentation checks run with `python3 Scripts/validate-documentation.py`. Native build and Simulator commands and their actual results are recorded in [validation](Docs/Development/updated-project-validation.md). There is no SwiftPM package yet.

## Development workflow

Complete one task at a time: implement, exercise the behavior, add unit/regression tests, run relevant checks (including native iPhone Simulator coverage for shared/mobile changes), review the diff, and make a separate commit. Tests belong with the change they validate.

The first application milestone is the Phase 1 critical path: create a workspace, project, and agent; edit instructions; execute through Codex CLI; watch live steps; inspect results and file changes. Secure LAN/mobile execution follows the staged roadmap; mobile compilation and simulator validation start when the native targets exist.
