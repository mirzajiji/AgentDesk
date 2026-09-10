# Implementation tasks and commit boundaries

This is an implementation plan, not a completion claim. The full source specification remains authoritative. B01 documentation is committed as `4d027e9`. P1-01 native acceptance passes on Mac and the user-selected iPhone 16 Pro. It is committed and pushed as `7b369f5`. P1-02 scoped identity and filesystem reads are committed and pushed as `c496060`; see [isolation validation](p1-02-validation.md). P1-03 local workspace/project management is committed and pushed as `f0d4d91`; see [catalog validation](p1-03-validation.md). See the table below for current completion. See [foundation validation](p1-01-validation.md).

Finish the current task's validation and commit before starting another independent task. A task may be split further when its diff becomes difficult to review; never combine unrelated completed tasks just to reduce commit count. Behavioral tests belong in the feature commit.

Progress after P2-10a: **43 documented tasks complete, 0 Phase 1 tasks remaining** (31 foundation tasks including bootstrap and regression fixes, plus 12 Phase 2 tasks). **Four Phase 2 tasks remain:** native Bug Registry, traceability/impact, duplicate/report review and Phase 2 acceptance. Phases 3–6 and their associated sections 115–159 additions also remain; those phases are not yet decomposed into commit-sized task counts. These counts are tasks, not a percentage of the full product.

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
| P1-06b2 | Complete: immutable execution/environment/policy settings, effective configuration with provenance and enforced output schemas | 88 Core + 68 Runtime tests; 205 native Mac unit + 1 Settings UI and 161 iPhone tests pass; real Codex structured-output smoke passes. See [configuration validation](p1-06b2-validation.md). |
| P1-06b3 | Complete: workspace/project skill bundles, native editor/attachments, archive/restore, pinned agent references and exact source/permission preview | 97 Core + 68 Runtime tests; 215 Mac unit tests, 11 distinct Mac UI executions across runs and 170 iPhone tests pass. See [skill validation](p1-06b3-validation.md) for initial selector failures and accepted retries. |
| P1-07a | Complete (`0ae202f`, pushed): shared run states, persisted lifecycle service and bounded replay/live state subscriptions | 12 Runtime + 58 Core + 12 persistence package tests; 97 native Mac and 92 iPhone unit tests pass. See [lifecycle validation](p1-07a-validation.md). |
| P1-07b | Complete (`189bdff`, pushed): typed persisted stages/steps and deterministic measurable progress | 66 Core + 18 persistence + 16 Runtime package tests; 115 native Mac and 110 iPhone unit tests pass. See [progress validation](p1-07b-validation.md). |
| P1-08a | Complete (`6be270b`, pushed): Codex discovery, supported version/status/login/logout adapters and bounded Mac command capture | Real installed CLI probe; 32 Runtime, 131 native Mac and 114 iPhone unit tests pass; see [diagnostics validation](p1-08a-validation.md) |
| P1-08b | Complete (`126132d`, pushed): native Codex Settings, persisted executable/connection configuration and signed Mac XPC account host | 67 Core + 36 Runtime tests, 140 native Mac unit + 10 UI and 115 iPhone unit executions pass; actual native health check uses the existing CLI account. See [Settings validation](p1-08b-validation.md). |
| P1-09a | Complete (`4472b90`, pushed): real bounded Mac subprocess transport with stdin, incremental stdout/stderr, deadlines and cleanup; diagnostics use the same transport | 43 Runtime, 147 native Mac unit + 1 Settings UI and 115 iPhone unit executions pass. See [transport validation](p1-09a-validation.md). |
| P1-09b | Complete (`6eaf67c`, pushed): internal read-only Codex ExecutionProvider, bounded JSON framing, verified project permissions and scoped observations | 57 Runtime, 161 native Mac unit + 1 Settings UI and 119 iPhone unit tests pass; real CLI reads synthetic evidence with exact result. See [provider validation](p1-09b-validation.md). Native run UI remains P1-13c. |
| P1-10 | Complete: deterministic policy, exact prepared-action binding, durable approval/audit ledger and internal dispatch gate | 70 Core + 12 Security + 25 Persistence + 64 Runtime tests; 183 native Mac unit + 1 Settings UI and 141 iPhone unit tests pass. See [policy validation](p1-10-validation.md). Native review UI remains P1-13c. |
| P1-11a | Complete: scoped run preparation, policy-gated execution coordinator, persisted progress/evidence and interruption recovery | 97 Core + 39 Persistence + 96 Runtime tests; 267 affected native Mac and 215 iPhone tests pass; normal signed Mac build passes. See [coordinator validation](p1-11a-validation.md). |
| P1-11b | Complete: signed Mac execution bridge and native run service using the existing Codex login | 106 Runtime, 278 affected native Mac and 215 iPhone tests pass; signed XPC integration and one explicit native Codex read-only smoke pass. See [bridge validation](p1-11b-validation.md). |
| P1-12a | Complete: scoped redaction, classified output types and bounded logical stream completion | 24 Security, 227 native Mac unit + 1 Settings UI and 182 iPhone 16 Pro tests pass. See [redaction validation](p1-12a-validation.md). Storage/coordinator integration is implemented in P1-12b/P1-11a. |
| P1-12b | Complete: immutable run/environment evidence binding, sanitized traces, artifact publication and recovery | 38 Persistence, 240 native Mac unit + 1 Settings UI and 195 iPhone tests pass. See [evidence validation](p1-12b-validation.md). Provider/coordinator integration is implemented in P1-11a/b. |
| P1-12c | Complete: internal read-only Git snapshots, dirty-baseline comparison and sanitized staged/working/baseline diff previews | 82 Runtime, 252 affected native Mac unit and 200 iPhone tests pass. See [capture validation](p1-12c-validation.md) for supported repositories and unavailable unchanged Mac Keychain/UI checks. |
| P1-13a | Complete: scoped native repository registration, durable selected-folder access and run-location provenance; UI assembly follows in P1-13c | 100 Core, 112 Runtime, 288 affected Mac and 218 iPhone tests pass; real native bookmark round-trip passes. External picker/relaunch acceptance remains P1-13c. See [registration validation](p1-13a-validation.md). |
| P1-13b | Complete: native execution setup service, explicit environment/policy proposals and current-context preparation | 106 Core, 113 Runtime, 295 affected Mac and 224 iPhone tests pass. Stale context cannot create a run; refreshed context still requires review. See [setup validation](p1-13b-validation.md). |
| P1-13c1 | Complete: native repository/execution setup screens, full JSON editing and resizable Mac editors | 310 Mac unit/integration, four Mac UI and 224 iPhone tests pass; external picker/relaunch, smart-quote regression and compact keyboard/action checks pass. See [validation](p1-13c1-validation.md). |
| P1-13c2 | Complete: native context inspector and live run/result console | Current-context review, exact approval, live state/cancellation, scoped saved runs and redacted result/diff inspection; 333 Mac unit/integration, ten native UI and 226 iPhone tests pass. See [validation](p1-13c2-validation.md). |
| P1-13c3 | Complete: run-start catalog contention regression | Bounded cancellable context-read retry, persistent contention fails closed, distinct diagnostics; 339 Mac unit/integration, four native diff/start checks and 228 iPhone tests pass. See [validation](run-start-contention-validation.md). |
| P1-14a | Complete: command palette and scoped native routing | Command-K search, existing-capability routing, stale selection rejection, single dispatch, model and native UI tests; [validation](p1-14a-validation.md) |
| P1-14b | Complete: basic menu bar status and run navigation | Persisted open-session counts, scoped cross-window focus, lifecycle cleanup, native UI tests, 341 Mac unit/integration and 228 iPhone tests; [validation](p1-14b-validation.md) |
| P1-14c | Complete: readiness, Settings routing and native layout pass | Cancellable local health checks, recovery routes, resizable editors and compact project actions; affected native tests, 346 Mac unit/integration and 228 iPhone tests. See [validation](p1-14c-validation.md). Physical display/final acceptance remains pending. |
| P1-15 | Complete: Phase 1 acceptance and live output | Real fresh-app Codex workflow, bounded redacted live text, 351 Mac unit/integration and eight affected UI tests, 228 iPhone tests, Release signing and docs checks. Full baseline scheme also passes; [acceptance record](p1-15-acceptance.md). Physical display/full-device acceptance remains final-product work. |

After P1-06a/b1, implementation follows the runtime critical path through P1-07a/b and Codex discovery/provider setup. P1-06b2 configuration constraints and P1-06b3 scoped skills are complete. Capabilities must be validated and policy-gated before being made executable. P1-12a/b/c evidence safety and capture precede coordinator P1-11 so real provider output has a tested storage boundary. All six phases and the additions below remain in scope.

The iOS target introduced in P1-01 is a truthful companion shell with an unpaired/connection-unavailable state. Do not fabricate active runs or working pairing before Phase 5 exists. Keep testing it whenever shared types or design code change.

The user's 32-inch 4K, 27-inch 2K, 16-inch 4K and 14-inch 4K Mac display targets apply to every phase. Follow the [display/window acceptance matrix](testing.md#mac-display-and-window-matrix); complete the full physical display matrix at final product acceptance, recording unavailable hardware rather than implying coverage. This is an acceptance requirement across existing tasks, not an additional completed task.

## Phase 2 — Project memory

Phase 2 is decomposed into 11 planned tasks (P2-06 split into index and context integration) plus the user-reported modal-spacing regression. The first storage task does not claim native editing, executable validation rules, retrieval or Bug Registry behavior; those have their own acceptance gates.

| Task | Status and scope | Acceptance |
| --- | --- | --- |
| P2-01 | Complete: immutable requirement store and active resolver | Exact reviewed proposals, immutable JSON/history, active resolution, conflicts, orphan recovery and scoped paging; 14 store regressions, 365 Mac and 242 iPhone tests. See [validation](p2-01-validation.md). |
| P2-02 | Complete: native requirement editing and review | Exact field review/publication, immutable history, status/environment editing and scoped commands; 383 Mac and 245 iPhone tests, plus 16 focused Mac tests. See [validation](p2-02-validation.md). |
| P2-03 | Complete: deterministic requirement validation | Typed bounded predicates, exact observed/expected values and resolved versions, explicit unavailable evidence, scope/environment checks and native rule review; 388 Mac and 253 iPhone tests pass. See [validation](p2-03-validation.md). |
| P2-03a | Complete: Requirements modal top-spacing regression | Header remains at the standard inset for empty and unselected lists in compact/large native windows; five affected Mac tests pass. See [validation](p2-03a-validation.md). |
| P2-04 | Complete: requirement traceability and stale links | Reviewed scoped relationships, exact creation references, latest-active reruns, explicit reproduction, stale/unavailable impact counts; 395 Mac and 261 iPhone tests pass. See [validation](p2-04-validation.md). |
| P2-05 | Complete: structured memory, notes and inbox storage | Separate scoped immutable records, exact source provenance, nonauthoritative intake and reviewed confirmation/edit/archive; 403 Mac and 269 iPhone tests pass. See [validation](p2-05-validation.md). |
| P2-06a | Complete: scoped rebuildable knowledge index | Redacted FTS5 snapshots, atomic rebuilds, classification/environment/path filters and query-bound paging; 411 Mac and 277 iPhone tests pass. See [validation](p2-06a-validation.md). |
| P2-06b | Complete: selective context and native run integration | Agent knowledge editor, authoritative revalidation/current relationships, bounded redacted context and readable native inspector bound to approval/dispatch; 433 full Mac tests, eight final presentation/layout/UI checks and 294 iPhone tests pass. See [validation](p2-06b-validation.md). |
| P2-07 | Complete: persistent Bug Registry and manual Jira links | Reviewed immutable records, link/unlink history, classified behavior, exact references and scoped relationships; 169 Core, 449 Mac and 308 iPhone tests pass. See [validation](p2-07-validation.md). Native management remains P2-10; no external issue creation. |
| P2-08 | Complete: duplicate detection and evidence preparation | Scoped current-requirement comparison, reviewed Codex ambiguity, immutable local overrides and sanitized known-ticket drafts; 185 Core, 145 Runtime and 326 iPhone tests pass. Mac: 476 passed; two unchanged Keychain tests fail with interaction-not-allowed. See [validation](p2-08-validation.md). Native management remains P2-10. |
| P2-09 | Complete: versioned CityPay bug-report skill | Native template, synthetic examples, scoped version pinning, current-requirement reports and same-root grouping; 191 Core, 146 Runtime, 332 iPhone tests pass. Mac: 483 initial passes and three successful unlocked rechecks, including native UI. See [validation](p2-09-validation.md). |
| P2-10a | Complete: native memory, notes and inbox | Scoped browser/editor, exact sanitized review, promotion/archive/ignore and immutable history; 192 Core and 333 iPhone tests pass, plus native Mac model/layout/UI checks. See [validation](p2-10a-validation.md). |
| P2-10b | Pending: native Bug Registry workspace | Scoped bug creation/editing, manual ticket links, immutable history, relationship navigation and empty/error states |
| P2-10c | Pending: native traceability and impact views | Requirement/test/workflow/documentation links, latest versus historical references, stale/impact inspection and reviewed edits |
| P2-10d | Pending: native duplicate and report review | Current evidence, deterministic/semantic comparisons, explicit decisions, known-ticket additions and CityPay report/group review |
| P2-11 | Pending: Phase 2 acceptance and documentation | Native latest-versus-historical scenario, stale tests, known duplicate with additional evidence, isolation, Mac/iPhone tests and docs |

These tasks include the Phase 2 bullets in section 110, retrieval in section 17 and the corresponding notes/inbox/relationship requirements. Later integration phases must consume these services through their policy boundaries; completing storage alone does not authorize model or mobile writes.

P2-10 was decomposed into four focused native UI commits on 2026-09-11; its scope is unchanged. This increases the remaining Phase 2 task count from two to five while keeping Phase 3–6 work outstanding.

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

The P1-14a intermittent approval/start follow-up is addressed by [P1-13c3](run-start-contention-validation.md), including a failing-before/passing-after real-lock regression and repeated native UI checks. The original failed run remains recorded in [P1-14a validation](p1-14a-validation.md); P1-15 acceptance now passes as recorded below.

The current [Phase 1 acceptance audit](p1-15-acceptance.md) maps section 110 requirements and records the verified integrated native critical slice and explicitly deferred final-product validation.
