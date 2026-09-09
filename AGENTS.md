# AgentDesk development instructions

## Repository ownership and commits

- This project belongs to the user's **personal GitHub account**, associated with `mirzajijieshvili@gmail.com`.
- Set `user.name` to `Mirza Jijieshvili` and `user.email` to `mirzajijieshvili@gmail.com` **locally in this repository**. Do not change global Git settings or the user's work GitLab identity.
- The user created the repository and explicitly supplied `https://github.com/mirzajiji/AgentDesk.git`. Use that exact personal remote; do not create another repository or change its visibility. Verify the effective commit author/committer and remote before pushing. Preserve existing remote history; never force-push without explicit authorization.
- Use `main` as the main branch and `codex/` for implementation branches. Do not overwrite an existing remote repository.
- Each separate task gets a separate, focused commit. For each important change: implement it, exercise the behavior, add or update meaningful unit tests, run those tests and affected checks, inspect the diff, then commit. Tests for a feature belong in the same commit as that feature.
- The user has authorized creating the personal GitHub repository and committing completed tasks. Do not repeatedly ask for confirmation for those actions. Respect actual environment restrictions and report blocked commits honestly.
- Do not claim tests passed when they were skipped or blocked. Record commands, results, simulator model, and OS version in the task's validation record. Do not substitute an iOS build for a simulator test run.
- Keep unrelated changes out of a task's commit. Do not accumulate multiple completed implementation tasks in one commit. Documentation-only tasks need documentation checks; do not invent unit tests for prose.

## Architecture

The supplied product specification is preserved in `Docs/Architecture/final-architecture.txt`. It defines 159 sections and six development phases. `Docs/Development/tasks.md` breaks initial implementation into commit-sized tasks. The specification describes the target product, not already implemented behavior.

- Native Swift and SwiftUI macOS application plus a native iPhone companion; Swift Package Manager for modules.
- The Mac is the execution authority. The iPhone observes, reviews, approves, and invokes explicitly allowed predefined operations.
- Planned modules: `AgentDeskCore`, `AgentDeskRuntime`, `AgentDeskProtocol`, `AgentDeskClient`, `AgentDeskPersistence`, `AgentDeskSecurity`, `AgentDeskMCP`, `AgentDeskPlugins`, `AgentDeskDatabases`, and `AgentDeskDesign` under `Packages/`.
- Use small domain types and services, dependency injection at subsystem boundaries, and deterministic code for known operations. Keep business logic out of SwiftUI views.
- Use `async/await`, actors, structured concurrency, `AsyncSequence`/`AsyncStream`, and `Sendable`. UI state belongs on `@MainActor`. Handle cancellation, timeouts, stream termination, and resource cleanup explicitly. Avoid unchecked sendability and giant observable models.
- Codex CLI is the only current AI provider, behind `ExecutionProvider`. No OpenAI API, `OPENAI_API_KEY`, Agents SDK, unofficial ChatGPT API, session-cookie extraction, React, Electron, Tauri, or mandatory cloud backend.
- Detect installed CLI capabilities and use supported login/logout/status mechanisms. Launch subprocesses with argument arrays, never interpolated shell commands. Keep model names in provider configuration, not domain code. Unavailable provider usage stays unavailable.

## Data and isolation

- Human-readable JSON/Markdown (YAML where appropriate) is authoritative for configuration and project memory. SQLite stores runs, steps, traces, approvals, artifacts metadata, audit events, and other operational state.
- Every operation carries workspace/project identity and environment/run/agent identity where applicable. Enforce scope in filesystem resolution, persistence queries, retrieval, plugin/MCP/database calls, logs, analytics, artifacts, and remote responses.
- Resolve and validate paths, including traversal, absolute paths, sibling-prefix collisions, and symlink escapes. Do not rely on prompts to prevent cross-company access.
- Store actual company data outside the tracked source tree. `Workspaces/` and `Data/` are ignored runtime locations. Test fixtures must be synthetic.
- Secrets belong in a Mac Keychain-backed `SecretStore` with set/get/delete/exists operations. Use scoped references in files. Never put secret values in logs, traces, artifacts, analytics, backups, or mobile payloads.
- Apply centralized redaction before persistence and display. Keep observed evidence distinct from agent interpretation, with source/provenance and environment snapshots.

## Project knowledge and bugs

- Requirement versions are immutable. Create a new version plus a current-version pointer; never overwrite historical content.
- New tests, normal reruns, expected results, and bug analysis resolve the latest active requirement by default. Historical reproduction must be explicit. Record exact requirement versions and identify stale tests and affected links.
- Maintain a persistent project-scoped Bug Registry, including manually registered external tickets.
- Before external bug creation, check current requirements and observed root behavior, search duplicates using deterministic fingerprints first, and use Codex only for semantic ambiguity. A known duplicate prepares additional evidence for the existing ticket. Blocked downstream behavior must not be reported as verified defects.
- Authoritative memory changes need explicit review; uncertain findings belong in notes/inbox/evidence.

## Integrations, permissions, and mobile

- Plugins expose normalized capabilities and independently scoped configuration, health, authentication, lifecycle, and permissions. Implementations may use REST, CLI, native Swift, or MCP.
- MCP is a separate first-class protocol for tools, resources, prompts, transports, local processes, discovery, health, and logs. It is never automatically trusted.
- Database connections are project/environment scoped. PostgreSQL comes first behind a driver abstraction. Classify SQL deterministically, including the highest risk of multi-statement requests; enforce policy before execution. Credentials remain in Keychain.
- Every meaningful operation crosses the policy boundary: allow, approval, or deny. Bind approvals to the exact action, resource, scope, and payload; do not let the model bypass them. Fail closed on missing authority.
- Treat the specification's runtime approval rules separately from the user's authorization to develop and commit this repository.
- LAN access uses a native Swift Mac server, Bonjour discovery, authenticated paired devices, cryptographic identity, revocation, and shared Codable protocol types. Same Wi-Fi is not authorization. Remote access should require explicit enablement.
- Active mobile progress uses authenticated live socket events and sequence-based reconnection/replay. The Mac owns authoritative progress. Never invent numerical progress for open-ended runs.
- Enforce mobile restrictions on the server: no secret access, arbitrary shell, direct company infrastructure/database access, arbitrary configuration changes, or security-policy bypass. Respect local-network privacy declarations and show permission denial distinctly from offline state.
- Known Postman/scenario execution uses deterministic runners without Codex. Calendar data is scheduling context by default and must not flow automatically into agent prompts or other workspaces.

## Adding capabilities

- Agent: add a validated, workspace-scoped definition with instruction references, execution profile, skills, tool permissions, environment/project scope, limits, and output schema. Add CRUD/isolation/provider tests and a synthetic fixture.
- Skill: add a scoped bundle with `skill.json`, `instructions.md`, and optional examples/scripts; validate paths and required permissions. Skills do not grant authority.
- Plugin: implement the normalized capability/lifecycle boundary, scoped configuration and Keychain references, health diagnostics, and allow/approval/deny tests.
- MCP: implement the transport/capability boundary, process cleanup, discovery and health; test denied tools, scope isolation, restart/failure, and redaction.
- DB driver: implement the database abstraction and safe parameter handling; route through SQL classification, scope checks, Keychain, policy, and approval. Test read/write/destructive denial cases.
- Workflow node: add a typed, versioned definition, input/output validation, policy integration, run events, timeout/cancellation, deterministic retry behavior, and tests with fake providers. Named resource locks must release on all exit paths.
- Extend interfaces only when implementing a real capability. Do not mark placeholders, empty modules, or mock-only flows as complete features.

## Validation

- Follow `Docs/Development/testing.md`. Unit tests are required for behavioral changes and regression fixes. Use fake providers and isolated temporary storage; live Codex/company access must not be a prerequisite for ordinary unit tests.
- Cover happy paths, failure paths, cancellation, timeouts, isolation, malformed input, and permission enforcement where relevant.
- Build macOS and iOS targets for shared-code changes. During development, run native Mac tests and use iPhone 16 Pro as the primary local Simulator device (user update, 2026-09-09). Defer the compact/large and minimum/newest iOS runtime matrix until final full-project acceptance. Record unavailable runtimes rather than claiming coverage.
- Test native UI behavior, accessibility/Dynamic Type, keyboard and navigation, empty/error states, run updates, diffs, and approvals as those features arrive. A responsive web preview is not an iPhone emulator.
- Before a feature commit, run affected unit/integration/UI tests and review staged content for credentials, company data, build output, and unintended files.
- A feature blocked by missing tools or permissions remains incomplete. Do not continue building a backlog of uncommitted completed tasks when the commit gate cannot be satisfied.
