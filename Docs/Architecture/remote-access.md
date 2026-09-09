# Mac authority and iPhone companion API

Status: planned design. Source: [final architecture](final-architecture.txt), sections 84, 89–93 and 98.
<!-- Source sections: 84,89,90,91,92,93,98 -->

The Mac exposes an authenticated native Swift server for scoped workspaces/projects, runs/steps, artifacts/diffs, approvals, health and pairing. Shared Swift Codable types define a versioned internal protocol. No FastAPI or required cloud host is part of this design.

## Companion capabilities

Permitted mobile views include active/recent runs, current/completed/pending stages, tool activity, public summaries, timelines, artifacts/screenshots/Markdown, sanitized logs, changed files and diffs. Permitted commands can include approve/reject, cancel, pause/resume where supported, and start predefined agents/workflows.

All such actions are subject to device and workspace/project policy. Mobile cannot view secrets/passwords, modify raw security policies or MCP credentials, run arbitrary shell, access company databases directly, edit arbitrary configuration, alter isolation, or bypass approval. Enforce restrictions on the server, including malformed or manually constructed client requests.

## Protocol design to implement

Use explicit safe response projections, not automatic serialization of internal database records. Command payloads should carry scope, resource identity and an idempotency/request identity where needed. Define protocol version negotiation, schema validation, authorization failures, size limits, replay behavior and compatibility tests before enabling transport.

Run detail shows stage/step state, elapsed time, public summaries and changed files from the same Mac-authoritative state used on desktop. Diffs offer file lists, additions/removals and collapsible unified hunks; initial mobile editing is read-only.

Approval detail shows the exact action, scope, target, branch/diff or payload. Device authentication can protect high-risk approval, but it does not replace server policy. Approved work executes on the Mac and returns an authoritative result, including any changed-state conflict or failure.

## Verification

Test unpaired and revoked clients, cross-scope IDs, forbidden secret/shell/database requests, response redaction, malformed/oversized commands, unsupported protocol versions, duplicate commands, changed approval payload and reconnect during an action. Test native iPhone navigation, diffs, errors and accessibility on the required simulator matrix. Do not show invented working remote functionality in the Phase 1 shell.
