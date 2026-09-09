# Runs, steps and provider execution

Status: planned design. Source: [final architecture](final-architecture.txt), sections 66–67.
<!-- Source sections: 66,67 -->

Every agent or workflow execution creates a Run with explicit workspace/project ownership. Runs record identity, parent run, agent/workflow references, task, status, creation/start/completion times, execution profile, environment, working directory, result/error, artifact references and trace identity.

## State model

Run statuses are queued, running, waitingForApproval, paused, completed, failed and cancelled. Exact allowed transitions require implementation tests. Proposed baseline: queued can start or cancel; running can wait, pause or finish; approved/resumed work returns to running; terminal states do not reopen. A rerun creates a new Run rather than rewrites a historical terminal record.

Separate a user pause, approval wait and queued resource wait so the UI explains why progress stopped. Provider loss and process exit are events to interpret, not automatic evidence that a task succeeded. Completion requires an accepted result and required validations.

## Explicit work structure

RunSteps expose meaningful actions such as load requirements, search documentation, inspect repository, analyze tests, implement automation, execute tests, analyze failures and report. A larger stage can group child steps. Stage/step status and measurable progress come from runtime state. Open-ended reasoning displays activity and stages without invented percentages.

Before starting, freeze an effective context snapshot, check scope and policy, run prerequisites, reserve scheduler capacity, create execution records, and launch the selected provider or deterministic tool. Persist safe output/events and result metadata. Release reservations and clean up execution resources on every exit path.

Proposed recovery behavior: on launch, reconcile nonterminal persisted runs against real process/session state. Mark lost execution explicitly; never pretend to resume a provider session that cannot be recovered. Preserve prior output and expose safe rerun/reproduction choices.

## Verification

Test valid and invalid state transitions, timestamp consistency, exactly-once terminalization, duplicate/out-of-order provider events, cancellation before and during execution, approval/rejection/expiry, timeout, coordinator restart and orphan-process handling. Integration tests should execute fake providers emitting partial stdout/stderr and failing at defined boundaries.

See [Codex](codex.md), [run events and evidence](run-events.md), [permissions](permissions.md), [reproducibility](reproducibility.md) and [persistence](persistence.md).
