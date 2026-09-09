# Workflows, scheduling and execution controls

Status: planned design. Source: [final architecture](final-architecture.txt), sections 22, 120, 126, 127 and 134–136.
<!-- Source sections: 22,120,126,127,134,135,136 -->

Workflows combine deterministic operations with agent reasoning in readable, versioned definitions. Supported node categories include agent, command, tool, plugin, MCP, approval, condition, branch, retry, timeout and artifact generation; parallel execution is a later capability.

## Node lifecycle

Proposed node contract: typed inputs and outputs, declared required capabilities, validation, timeout/cancellation, emitted progress, and a result that distinguishes success, product failure, infrastructure error, blocked, skipped and cancelled. Map node outcomes into the authoritative run/step state without treating every failure as a product defect.

Retries need explicit limits and side-effect semantics. A timed-out request may already have executed remotely; never automatically repeat writes unless the adapter can establish idempotence or determine the previous result. Cancellation must clean up child processes and release resource reservations.

## Preflight and fallbacks

Before execution, check declared requirements deterministically: Codex readiness, repository/branch state, integration health, environment availability, collections and required network/VPN access. A failed mandatory prerequisite blocks execution with an actionable reason; do not discover a predictable missing connection after many agent steps.

Fallback implementations, such as Jira MCP to a native plugin or a native runner to Newman, are configurable and visible. Reevaluate scope, permissions, supported behavior and prerequisites. A fallback cannot silently broaden privileges or reinterpret unsupported assertions.

## Budgets and queues

Agents/workflows can declare maximum duration, Codex calls, tool calls, retries, concurrent subprocesses and generated artifacts. Reaching a budget produces a paused/budget-exhausted state with explicit continue/stop choices. Track consumption in runtime code rather than trust a model to stop itself.

Scheduler limits can apply globally and per workspace/resource. Show queued position and reason. Named exclusive locks coordinate shared test accounts, environments, deployments or migrations. Include workspace/environment in lock identity and release locks on success, failure, timeout and cancellation. Proposed crash recovery uses durable ownership and reconciliation; it must not steal a lock from a still-running operation.

## Task templates

Quick actions capture agent/workflow, project, environment, inputs, execution profile, required connections and approval behavior. They are accessible from Mac navigation, command palette, menu bar and eventually permitted mobile/MCP actions. A template references a capability; it does not bypass preflight or policy.

Verify branches, input validation, retries, timeouts, uncertain writes, cancellation, queue fairness, budget exhaustion/resume, lock cleanup, version snapshots and no privilege escalation through fallback. Use fake providers and deterministic test clocks where appropriate.
