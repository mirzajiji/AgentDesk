# Implementation tasks and commit boundaries

This is an implementation plan, not a completion claim. The full source specification remains authoritative. B01 documentation is validated and ready for its separate commit; Phase 1 tasks remain pending. Source and Git writes now work. The [current validation record](updated-project-validation.md) records remaining native-development and network limitations.

Finish the current task's validation and commit before starting another independent task. A task may be split further when its diff becomes difficult to review; never combine unrelated completed tasks just to reduce commit count. Behavioral tests belong in the feature commit.

## Bootstrap

| Task | Deliverable | Validation / completion |
| --- | --- | --- |
| B01 | Preserve all 159 architecture sections; development instructions, ignore rules, repository setup and testing plan | Imported and validated: integrity, 159-section coverage, links and ignore rules; Git write access restored; separate documentation commit follows validation |

## Phase 1 — Native Mac foundation

| Task | Deliverable | Required evidence before its commit |
| --- | --- | --- |
| P1-01 | SwiftPM module foundation, native Mac/iOS app targets, shared schemes, test targets, selected deployment versions | Mac build/launch, shared unit tests, iPhone simulator build/launch/UI smoke test; record model and OS |
| P1-02 | Typed workspace/project/environment/run/agent IDs and workspace-scoped filesystem resolver | Serialization and invalid IDs, traversal/absolute path/sibling-prefix/symlink escape rejection |
| P1-03 | Filesystem workspace/project creation, validation, listing and reopening | CRUD/persistence, malformed configuration, duplicate names/IDs and cross-scope rejection |
| P1-04 | SQLite operational store and explicit versioned migrations | Reopen, migration, rollback/transaction and cross-workspace query tests |
| P1-05 | Keychain SecretStore abstraction plus injectable test store | Scoped set/get/delete/exists, missing item/error behavior; no plaintext persistence |
| P1-06 | Agent CRUD, templates, instruction editing and configuration composition | Round trips, effective source order, missing/invalid references, cycles, cross-scope denial |
| P1-07 | Typed run/step/event models, lifecycle transitions and event bus | Valid/invalid transitions, cancellation, ordered delivery, subscriber cleanup and deterministic progress |
| P1-08 | Codex discovery, supported version/status/login/logout adapters and Settings UI | Installed/missing/logged-out/error fixtures; supported CLI capability verification; no credential extraction |
| P1-09 | Codex ExecutionProvider with arguments/stdin, streaming, cancellation, timeout and exit handling | Fake executable tests including prompt injection strings, split output, stderr, exit errors, process cleanup |
| P1-10 | Workspace-aware policy and approvals foundation | Allow/approval/deny, exact approved payload, expired/rejected approval, cross-scope and remote privilege rejection |
| P1-11 | Run execution coordinator with scoped instructions and real provider adapter | Fake-provider end-to-end run; failure/cancel/restart persistence; supported live smoke test when available |
| P1-12 | Redacted traces, artifacts, repository snapshots and changed-file/diff collection | Redaction before writes, scope isolation, dirty starting state, added/modified/deleted/renamed files |
| P1-13 | Native navigation, workspace/project/agent editors, context inspector and live run/result UI | Mac UI critical path, keyboard/accessibility, validation/errors; shared/mobile regression suite |
| P1-14 | Command palette, basic menu bar, Settings and first-run checks | Command routing, stale selection handling, no duplicate execution, menu status updates and UI tests |
| P1-15 | Complete Phase 1 acceptance and architecture documentation for implemented systems | Fresh app: workspace → project → agent → instructions → Codex → live steps → results/files; all affected suites |

The iOS target introduced in P1-01 is a truthful companion shell with an unpaired/connection-unavailable state. Do not fabricate active runs or working pairing before Phase 5 exists. Keep testing it whenever shared types or design code change.

## Later phases

Break each row below into independent feature commits using the same validation gate when that phase begins.

| Phase | Work and acceptance focus |
| --- | --- |
| 2 — Project memory | Structured records, immutable requirement versions/latest-active resolution, diffs, traceability/staleness/impact, Bug Registry, manual Jira links, root-behavior duplicate detection, blocked scenarios, CityPay bug formatting |
| 3 — Connections | Plugin/capability lifecycle, Jira, scoped permissions/authentication, MCP transport/discovery/process management, database framework/PostgreSQL, deterministic SQL policy, schema browsing and real diagnostics |
| 4 — Workflows | Versioned mixed deterministic/agent nodes, conditions/branches/retries/timeouts, delegation, QA flows, preflight, budgets, queue limits, named locks, evidence relationships |
| 5 — iPhone / LAN | Native Mac control server, Bonjour, secure pairing/device credentials/revocation, workspace authorization, live sockets/replay/reconnect, native run/diff/artifact/approval views, denied mobile capabilities, local simulator matrix and physical-device acceptance |
| 6 — Advanced platform | AgentDesk MCP server, evals, workflow editor, local analytics/usage, notifications, richer menu bar, history, scheduling, optional VPN/relay abstractions |

## Additions retained in scope

Sections 115–159 add deterministic Postman/scenario execution, project analytics, reproducible environment snapshots, provenance, evidence quality, quick actions, clone/compare runs, coverage maps, test data, preflight/fallbacks, workspace lock/production safety/dry run, versioned workflows/agents, budgets/concurrency/locks, retention/classification/redaction/audit, connection diagnostics/onboarding/import/OpenAPI/drift, repository registration/safety, notes/inbox/timeline/deep links, backup/restore, extensions, local CLI/CI, and calendar integration.

These additions must be scheduled explicitly into later tasks; they are not omitted or silently considered implemented by the Phase 1 scaffold. Calendar starts with provider abstraction, a compact upcoming-event widget and daily timeline, with privacy/permission and offline-cache tests.
