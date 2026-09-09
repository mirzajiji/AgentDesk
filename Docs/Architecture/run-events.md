# Operational events, traces, artifacts and provenance

Status: planned design. Source: [final architecture](final-architecture.txt), sections 68–70, 102, 118–119.
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
