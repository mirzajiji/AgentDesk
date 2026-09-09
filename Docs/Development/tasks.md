# Implementation tasks and commit boundaries

This is an implementation plan, not a completion claim. The full source specification remains authoritative. B01 documentation is committed as `4d027e9`. P1-01 native acceptance passes on Mac and the user-selected iPhone 16 Pro. It is committed and pushed as `7b369f5`. P1-02 scoped identity and filesystem reads are committed and pushed as `c496060`; see [isolation validation](p1-02-validation.md). P1-03 local workspace/project management is committed and pushed as `f0d4d91`; see [catalog validation](p1-03-validation.md). Later tasks remain pending. See [foundation validation](p1-01-validation.md).

Finish the current task's validation and commit before starting another independent task. A task may be split further when its diff becomes difficult to review; never combine unrelated completed tasks just to reduce commit count. Behavioral tests belong in the feature commit.

## Bootstrap

| Task | Deliverable | Validation / completion |
| --- | --- | --- |
| B01 | Preserve all 159 architecture sections; development instructions, ignore rules, repository setup and testing plan | Complete: integrity, 159-section coverage, links and ignore checks; committed as `4d027e9`; pushed to the personal GitHub remote |

## Phase 1 — Native Mac foundation

| Task | Deliverable | Required evidence before its commit |
| --- | --- | --- |
| P1-01 | Complete: Core/Design packages, native shell, shared scheme, Swift 6, macOS 15/iOS 18 targets and tests | 5 SwiftPM tests; native Mac 10 executions and iPhone 16 Pro/iOS 26 13 executions pass; see validation. Final device/OS matrix deferred by user. |
| P1-02 | Complete: typed workspace/project/environment/run/agent IDs and workspace-scoped filesystem resolver | 21 SwiftPM and 22 native tests each on Mac and iPhone 16 Pro pass; traversal, cross-scope, symlink/hardlink, cancellation and size limits |
| P1-03 | Complete: filesystem workspace/project creation, validation, listing, renaming, reopening and native Mac forms | 31 package tests; Mac 35 unit + 6 UI and iPhone 16 Pro 32 unit + 7 UI executions pass. Delete/archive and repository registration remain later work. |
| P1-04 | Complete (`d88eca0`, pushed): SQLite operational run store and explicit versioned migrations | 12 package tests; 47 native Mac and 44 iPhone 16 Pro unit executions pass; see [persistence validation](p1-04-validation.md) |
| P1-05 | Complete (`63cfb0b`, pushed): Keychain SecretStore abstraction plus injectable test store | 7 isolated tests; 56 native Mac and 53 iPhone unit tests pass, including real Keychain integration. See [validation](p1-05-validation.md). |
| P1-06a | Complete (`6664313`, pushed): project agent creation/editing, templates, immutable instruction versions, archive/restore and native Mac editor | 43 package tests; 68 native Mac unit + 8 UI and 65 iPhone 16 Pro unit executions pass. See [agent editing validation](p1-06a-validation.md). |
| P1-06b1 | Complete (`d98f5b1`, pushed): versioned workspace/project instruction sets, include composition and native exact-source preview | 56 package tests; 83 native Mac unit + 9 UI and 78 iPhone 16 Pro unit executions pass. See [instruction validation](p1-06b1-validation.md). |
| P1-06b2 | Effective execution configuration, environment constraints and output schemas | Override provenance, restrictions that cannot be widened, invalid schemas and deterministic output validation |
| P1-06b3 | Scoped versioned skills and agent skill references | Bundle/path validation, permission requests without grants, source preview, version pinning and cross-scope denial |
| P1-07a | Complete: shared run states, persisted lifecycle service and bounded replay/live state subscriptions | 12 Runtime + 58 Core + 12 persistence package tests; 97 native Mac and 92 iPhone unit tests pass. See [lifecycle validation](p1-07a-validation.md). |
| P1-07b | Typed persisted stages/steps and deterministic measurable progress | Stage/step transitions, event replay, unknown progress, monotonic known-work counters and failure/cancel behavior |
| P1-08 | Codex discovery, supported version/status/login/logout adapters and Settings UI | Installed/missing/logged-out/error fixtures; supported CLI capability verification; no credential extraction |
| P1-09 | Codex ExecutionProvider with arguments/stdin, streaming, cancellation, timeout and exit handling | Fake executable tests including prompt injection strings, split output, stderr, exit errors, process cleanup |
| P1-10 | Workspace-aware policy and approvals foundation | Allow/approval/deny, exact approved payload, expired/rejected approval, cross-scope and remote privilege rejection |
| P1-11 | Run execution coordinator with scoped instructions and real provider adapter | Fake-provider end-to-end run; failure/cancel/restart persistence; supported live smoke test when available |
| P1-12 | Redacted traces, artifacts, repository snapshots and changed-file/diff collection | Redaction before writes, scope isolation, dirty starting state, added/modified/deleted/renamed files |
| P1-13 | Native navigation, workspace/project/agent editors, context inspector and live run/result UI | Mac UI critical path, keyboard/accessibility, validation/errors; shared/mobile regression suite |
| P1-14 | Command palette, basic menu bar, Settings and first-run checks | Command routing, stale selection handling, no duplicate execution, menu status updates and UI tests |
| P1-15 | Complete Phase 1 acceptance and architecture documentation for implemented systems | Fresh app: workspace → project → agent → instructions → Codex → live steps → results/files; all affected suites |

After P1-06a/b1, implementation follows the runtime critical path through P1-07a/b and Codex discovery/provider setup. P1-06b2/b3 configuration constraints and skills remain required work; capabilities must be validated and policy-gated before being made executable. All six phases and the additions below remain in scope.

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
