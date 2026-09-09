# Continue AgentDesk in the updated local project

Current continuation: the user moved the app to `/Users/mirza/Documents/ChatGPT/AgentDesk/AgentDeskProject/AgentDesk`. Source and Git writes now succeed on `codex/native-foundation`; finish B01 and proceed through the task plan. GitHub DNS and CoreSimulator remain blocked. See [current validation](updated-project-validation.md). The original handoff below is historical; do not repeat the documentation import or move any Git metadata.

## Original handoff

The user authorized implementation and a new task in the updated AgentDesk project. Continue doing the work; do not stop at a plan or ask again whether to begin.

## Current project and repository

- Saved local project root: `/Users/mirza/Documents/AgentDeskProject`.
- Actual Git repository and Xcode project: `/Users/mirza/Documents/AgentDeskProject/AgentDesk`.
- Exact personal remote: `https://github.com/mirzajiji/AgentDesk.git`.
- Last verified state: clean `main` tracking `origin/main`, commit `89905ae` (`Initial Commit`). Recheck before changes.
- Repository-local author: `Mirza Jijieshvili <mirzajijieshvili@gmail.com>`. Do not change global settings or use the work GitLab identity `mirza.jijieshvili@cactus-now.com`.
- The user permits related projects under `AgentDeskProject`, including runtime/backend projects where appropriate. Follow the native Swift architecture and keep implementation versioned; do not create a web/Python backend simply because a sibling directory is possible.

## Authoritative context to read

The user explicitly adopted the development rules in:

`/Users/mirza/Documents/ChatGPT/AgentDesk/AGENTS.md`

Apply them together with any applicable instructions in the new directory hierarchy. Read the full product specification and plans:

- `/Users/mirza/Documents/ChatGPT/AgentDesk/Docs/Architecture/final-architecture.txt`
- `/Users/mirza/Documents/ChatGPT/AgentDesk/Docs/Development/tasks.md`
- `/Users/mirza/Documents/ChatGPT/AgentDesk/Docs/Development/testing.md`

The architecture contains all 159 sections. SHA-256: `b7475d91fc2464c790183d82e74024025c17d8cee1120021910549a0f17cfd51`.

Original user attachment, if needed:

`/Users/mirza/.codex/attachments/bc556182-4c32-42c6-b104-66e356d92c59/pasted-text.txt`

Earlier bootstrap documentation and `.gitignore` exist only in the old `/Users/mirza/Documents/ChatGPT/AgentDesk` directory and are uncommitted. First bring the relevant architecture, instructions, ignore rules, and development documentation into the real repository. Adapt stale README/setup/status claims to the existing Xcode app and supplied remote. Never copy the old `.git` directory. Validate and commit this documentation task separately.

## Authorized development workflow

Implement one coherent task, exercise it, add meaningful unit/regression tests, run affected checks, inspect the diff, then commit the feature and tests together. Each separate task gets a separate focused commit. Documentation-only work uses integrity/link checks rather than artificial unit tests.

Use `codex/` implementation branches, preserve `main` and existing remote history, and never force-push. The user authorized commits and pushes to the personal remote. Verify effective author/committer and remote before pushing; do not repeatedly request authorization already supplied.

Do not accumulate unrelated completed tasks in one commit or a backlog of completed uncommitted work when the commit gate cannot be satisfied. Do not report skipped or blocked tests as passing.

## Implementation objective

Begin Phase 1 of the six-phase architecture and persist through its native Mac foundation in tested commits. The critical path is:

Create workspace → create project → create agent → edit instructions → execute through Codex CLI → view live steps → inspect result and changed files.

Phase 1 includes navigation, filesystem workspace/project configuration, SQLite, Keychain abstraction, agent CRUD/instructions/configuration composition, Codex detection and supported login/status/provider integration, typed runs/steps/events, live output, traces, artifacts, file/diff collection, approvals foundation, command palette, basic menu bar, and tests.

AgentDesk uses native Swift/SwiftUI, Swift Package Manager, structured concurrency, scoped human-readable configuration, SQLite operational data, and Keychain secrets. The Mac executes; the iPhone is a limited client. Codex CLI is the only AI provider. No OpenAI API, `OPENAI_API_KEY`, Agents SDK, unofficial ChatGPT APIs/cookies, React, Electron, Tauri, or mandatory cloud.

Enforce company/workspace/project isolation in code, including path traversal/symlink checks and scoped persistence/integrations/mobile responses. Policy is allow/approval/deny outside the model. Redact before persistence/streaming, bind approvals to exact actions/payloads, and keep secrets on the Mac. Requirements are immutable/versioned, tests use latest-active requirements by default, and external bug creation requires duplicate detection.

Plugins, MCP, and databases are scoped first-class abstractions. LAN uses a native Mac server, Bonjour, cryptographic pairing/revocation, and authenticated socket events with sequence-based replay/reconnection. Mobile cannot access secrets, arbitrary shell, direct company databases, or bypass policy. Keep the initial companion shell truthful until Phase 5 remote features exist. All architecture additions through section 159 remain in scope for later phases.

## Existing scaffold and validation

The Xcode repository currently contains the default SwiftUI Hello World multiplatform target and template unit/UI tests. Files include `AgentDesk.xcodeproj`, `AgentDesk/AgentDeskApp.swift`, `AgentDesk/ContentView.swift`, assets, `AgentDeskTests`, and `AgentDeskUITests`.

Last inspected settings: macOS/iOS/visionOS deployment targets 26.0, Swift language version 5.0, default actor isolation MainActor, app sandbox enabled. Review and evolve these deliberately for the Mac+iPhone architecture and modern Swift concurrency. Template tests do not constitute meaningful feature coverage.

The user explicitly requires native iPhone testing in Apple's local Simulator. Test representative compact/large iPhones and minimum-supported/newest-installed supported iOS versions where available. Record exact model, OS, commands, results, and gaps. Build-only checks or web viewport emulation are not simulator tests. Build/test Mac and iOS for shared changes. Use synthetic data, fake providers, and isolated temporary stores for ordinary tests; do not require live company credentials or paid Codex runs. Physical-device LAN/security acceptance remains separate.

Xcode 26.0 (17A324) and Swift 6.2 were installed. In the old task, simulator discovery failed due to sandbox/service restrictions. An unmodified baseline Mac build failed because `sandbox-exec` could not launch the Swift preview macro implementation. This was environmental evidence, not a proven source defect. Log: `/private/tmp/AgentDesk-baseline-20260909.log`.

## Why a new task is needed

The old task retained `/Users/mirza/Documents/ChatGPT/AgentDesk` as its working directory and writable workspace after the saved project was updated. It could read the new repository but could not create a temporary source write probe or the branch `codex/native-foundation`. No branch or implementation changes were made there.

Check actual source, Git, network, and simulator access in the new task promptly. Do not assume old failures persist or that new access is automatically sufficient. Report exact remaining blockers; do not circumvent sandbox restrictions, move `.git`, disable security controls, or extract credentials. GitHub browser access had been declined in the old task; do not use alternate browser routes to evade that restriction. Use authorized Git/CLI access when available.

The old task attempted to create the new task through the app tool, but the tool required approval while that session's approval policy was `never`. No new task was created by that attempt.
