# Runs, steps and provider execution

Status: persisted run lifecycle, live/replay events and typed stage/step progress are implemented in P1-07a/b. An internal read-only Codex provider is implemented in P1-09b; P1-10 adds the internal policy/approval gate; preflight configuration, redaction and recovery coordination remain subsequent tasks. See [lifecycle validation](../Development/p1-07a-validation.md) and [progress validation](../Development/p1-07b-validation.md). Source: [final architecture](final-architecture.txt), sections 66–67.
<!-- Source sections: 66,67 -->

Every agent or workflow execution creates a Run with explicit workspace/project ownership. Runs record identity, parent run, agent/workflow references, task, status, creation/start/completion times, execution profile, environment, working directory, result/error, artifact references and trace identity.

## State model

Run statuses are queued, running, waitingForApproval, paused, completed, failed and cancelled. The tested transition matrix permits queued → running/failed/cancelled; running → waitingForApproval/paused/completed/failed/cancelled; and waitingForApproval or paused → running/failed/cancelled. Terminal states do not reopen, and same-state updates are rejected. A queued run can fail before provider launch, for example during preflight. A rerun creates a new Run rather than rewrites a historical terminal record.

Separate a user pause, approval wait and queued resource wait so the UI explains why progress stopped. Provider loss and process exit are events to interpret, not automatic evidence that a task succeeded. Completion requires an accepted result and required validations.

## Explicit work structure

RunSteps expose meaningful actions such as load requirements, search documentation, inspect repository, analyze tests, implement automation, execute tests, analyze failures and report. A larger stage can group child steps. Stage/step status and measurable progress come from runtime state. Open-ended reasoning displays activity and stages without invented percentages.

Before starting, freeze an effective context snapshot, check scope and policy, run prerequisites, reserve scheduler capacity, create execution records, and launch the selected provider or deterministic tool. Persist safe output/events and result metadata. Release reservations and clean up execution resources on every exit path.

Proposed recovery behavior: on launch, reconcile nonterminal persisted runs against real process/session state. Mark lost execution explicitly; never pretend to resume a provider session that cannot be recovered. Preserve prior output and expose safe rerun/reproduction choices.

## Verification

Test valid and invalid state transitions, timestamp consistency, exactly-once terminalization, duplicate/out-of-order provider events, cancellation before and during execution, approval/rejection/expiry, timeout, coordinator restart and orphan-process handling. Integration tests should execute fake providers emitting partial stdout/stderr and failing at defined boundaries.

See [Codex](codex.md), [run events and evidence](run-events.md), [permissions](permissions.md), [reproducibility](reproducibility.md) and [persistence](persistence.md).

## Implemented lifecycle boundary

`RunState` is a shared Core type; the existing persistence name remains a compatibility alias and stored values/schema are unchanged. `RunLifecycleService` in `AgentDeskRuntime` is bound to one exact project and wraps the workspace-bound SQLite store. The Mac coordinator will own one service per project and route lifecycle mutations through it. Direct low-level persistence writes are not runtime authorization and must not be used as an alternative execution path.

The service validates scope, current state, expected sequence and a finite timestamp no earlier than the previous event. Each accepted mutation commits its state/event transaction before live delivery. A per-run operation gate spans storage suspension points, preventing another local mutation from overtaking publication or landing between replay and subscription registration. Conflicting same-run operations return `busy`; unrelated runs can proceed independently. Stale database sequences remain protected by SQLite's compare-and-commit check.

No prompt, arbitrary provider output, secret or interpreted result enters this initial state stream. Moving to `completed` represents an authoritative caller's decision; the later coordinator must verify output, policy, provider status and required checks before making that decision. This module alone neither launches a provider nor approves a tool. User-facing run execution remains unavailable until that coordinator is implemented.

Shutdown rejects new operations and closes active observers with a distinct `closed` error. Deallocation also finishes observers. Already-entered storage writes may finish durably; shutdown does not rewrite history or pretend that unreconciled provider processes completed. Startup/process reconciliation belongs to the provider coordinator.

## Implemented work plans

`RunWorkPlan` is a validated, versioned operational snapshot with exact project/run identity, stable stage/step IDs, parent-stage relationships, state, timestamps and optional measured units. It is configured once while queued, then updated only while the run is running. Paused/approval-waiting runs cannot advance work. It describes execution facts and does not grant execution permissions or define an executable workflow.

A fixed plan freezes its stage denominator before execution; completed and explicitly skipped stages count toward completion. It does not estimate partial stage completion. An open-ended plan may discover additional stages and always has no overall numerical percentage. Explicit step/stage counters require a known positive total, cannot decrease and cannot change denominator after the first measurement. Future deterministic runners must supply observed counts; provider reasoning must never manufacture them.

Steps require an active parent to start. Completion requires completed/skipped children and any explicit unit measurement to be complete. Failing or cancelling a stage cancels its unfinished children; skipping a stage skips its unfinished children. Run cancellation/failure finalizes unfinished items while preserving already-observed completed/failed states. A run cannot complete with unfinished or failed work. These constraints complement the later coordinator's result and policy validation.

Plans allow at most 32 stages and 128 steps, with titles bounded to 160 UTF-8 bytes. JSON decoding validates the same graph/state/measurement invariants as mutations. All timestamps must be finite and chronological; operational writes use canonical SQLite Unix-time precision so live and replayed event values compare exactly. Typed titles are internal caller-supplied labels; arbitrary provider output still requires the separate redaction/event boundary.

The P1-09a internal Mac byte transport now supports bounded stdin, live stdout/stderr chunks and explicit process-exit/signal results. Diagnostics already use it. It has no run authority, filesystem-scope grant or UI/mobile endpoint. P1-09b adds provider-specific request validation, verified read-only roots and bounded event decoding. The later coordinator must enforce environment policy, redact observations and validate results before making agent tasks executable in the app; see [Codex transport](codex.md).


`ExecutionProvider` returns a cancellable bounded observation stream; it does not mutate persisted lifecycle state. `CodexCLIProvider` currently executes one ephemeral read-only turn per process. Scope is checked before launch and at output/termination boundaries. Its final event requires protocol and process success, but cannot itself authorize the lifecycle service to mark a run complete. The coordinator must bind the effective configuration, policy decision, redacted evidence and output-schema validation to that same run identity. See [provider validation](../Development/p1-09b-validation.md).


The internal `PolicyGate` now prepares allow/review/deny decisions and wraps dispatch with current scope/authority checks and durable one-time approval consumption. It accepts an application-prepared effect, not arbitrary model commands. The coordinator must supply authenticated principals, resolved resources, an immutable effective configuration and the exact payload whose digest was reviewed. Consumed approvals cannot be reused after a failed/cancelled or uncertain attempt. Existing lifecycle rows and provider observations remain separate until P1-11 joins them. See [policy and review contract](permissions.md).
