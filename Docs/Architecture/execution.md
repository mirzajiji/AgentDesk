# Runs, steps and provider execution

Status: the persisted run-state lifecycle and live/replay state subscriptions are implemented in P1-07a, with passing [native validation](../Development/p1-07a-validation.md). Steps/stages, provider execution, preflight/policy and recovery coordination are subsequent tasks. Source: [final architecture](final-architecture.txt), sections 66–67.
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
