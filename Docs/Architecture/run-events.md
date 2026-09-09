# Operational events, traces, artifacts and provenance

Status: durable run-state replay/live delivery is implemented in P1-07a; step/tool/output events, redaction and artifacts follow in subsequent tasks. Source: [final architecture](final-architecture.txt), sections 68–70, 102, 118–119.
<!-- Source sections: 68,69,70,102,118,119 -->

Use a typed internal event system for runs, steps, public Codex output, tools, plugins, MCP, databases, file changes, artifacts, approvals and terminal results. Events connect runtime observability, persistence, native UI and eventual mobile streaming.

## Proposed event envelope

Include event identity/type, schema version, workspace/project/run identity, monotonically increasing per-run sequence, timestamp and a validated payload. Define ordering scope explicitly; a per-run sequence is not a global total order. Durable sequence assignment and publication should have a tested consistency boundary so reconnect does not miss persisted transitions.

Use bounded asynchronous streams with subscriber cleanup. Specify overflow behavior: coalesce replaceable progress or require snapshot/replay rather than silently discard terminal events and approvals. Repeated deliveries must not duplicate state changes, artifacts, approvals or usage.

## Trace content

Persist operational facts: task, agent, step, public decision summary, routing decision, tool invocation, sanitized arguments/output, stdout/stderr, process status, validations, changed files, artifact references, errors and timing. Do not expose or claim access to hidden model chain-of-thought.

Structured logs include timestamp, level, workspace/project/run/agent, component, event and message. Apply centralized redaction before logs, traces, persistence, previews, analytics and mobile streaming. Raw logs should not be retained elsewhere as a supposedly temporary bypass.

## Artifacts and evidence

Artifacts include reports, plans, bug drafts, Markdown/JSON, screenshots, test evidence, patches, generated tests, API evidence and database evidence. Keep metadata in operational storage and files in scoped directories. Validate artifact paths and authorize downloads/previews independently of list access.

Evidence provenance includes identity/type, source and source reference, capture time, run/step, workspace/project/environment, content hash and artifact reference. Add request ID, HTTP status, connection ID, commit or ticket where supplied. A hash detects content changes but alone does not prove the source is trustworthy.

Display observed evidence separately from model interpretation. Express confidence using evidence completeness and understandable match-strength levels. Do not invent precise confidence percentages. If a deterministic scoring algorithm is later used, document and test its meaning and limits.

Verify ordering, replay/deduplication, stream cleanup/overflow, partial output, redaction boundaries, artifact containment, evidence hashes/classification, absent provenance and the separation of generated interpretation from observed facts.

## Initial state subscriptions

`RunLifecycleService.subscribe(to:in:after:capacity:)` returns an `AsyncThrowingStream` with ordered persisted state events after the caller's last sequence. Each event carries project/workspace/run identity, sequence, state and timestamp. Registration and initial replay share the lifecycle service's per-run gate. Clients should keep their own last successfully processed sequence and deduplicate by run/sequence when recovering.

Buffers retain the oldest events, defaulting to 256 entries, with a validated range of 1–999. If initial replay is larger than the requested capacity, subscription throws `replayRequired`; the client first loads paged history or a current snapshot. If a live consumer falls behind, it receives buffered events followed by `replayRequired`. No dropped completion is reported as successful stream termination. The authoritative event remains in SQLite and can be replayed after the client's last processed sequence.

Terminal state delivery finishes the stream. A subscription after an already-terminal run's latest sequence finishes empty. Unknown/future cursors and foreign scope are rejected. Explicit subscription cancellation, consuming-task cancellation, service shutdown and deallocation all release observers. Shutdown uses a distinct `closed` error, so a disconnected runtime is not confused with a completed run. Consumers that stop iterating without cancelling their task should explicitly cancel their subscription.

This is an internal Mac lifecycle boundary, also compiled/tested with shared code on iPhone. It is not yet a mobile transport or authorization API. Native remote pairing, authenticated sockets, policy-bound commands and richer sanitized payloads remain separate implementation gates.
