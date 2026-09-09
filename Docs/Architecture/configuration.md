# Configuration composition and versioning

Status: planned design. Source: [final architecture](final-architecture.txt), sections 8, 10 and 131–133.
<!-- Source sections: 8,10,131,132,133 -->

Configuration stays in readable JSON, Markdown and appropriate YAML. The UI edits these files through validated services. SQLite can index or cache configuration but is not its only authoritative copy.

## Effective configuration

Composition order is global → workspace → project → agent → workflow → run. Each resolved value should retain its source, and the user should be able to inspect effective configuration and effective instructions before execution.

The specification establishes layer order but does not define every merge rule. Proposed rule to finalize with tests: scalar values use an explicitly permitted more-specific override; collections use declared merge/replace semantics; security constraints are evaluated separately and cannot be widened merely by a later configuration layer. Do not implicitly concatenate credentials, permissions or environment access.

Instruction composition can reference shared security/QA principles, workspace conventions and agent-specific instructions. Shared content must be deliberately non-confidential or explicitly scoped. Never read another company's files while resolving includes. Detect circular references, missing files, invalid paths, malformed documents and incompatible schema versions, and show the responsible source.

## Review and versions

Requirements are always immutable/versioned as described in [requirements](requirements.md). Critical workflows, agents, skills and scenarios also need versioned definitions. A run records the exact resolved versions used so instruction, permission, output-schema and execution-profile changes are visible when comparing results.

Show diffs before significant agent configuration saves, especially changed tools, database access, permissions, delegation and model/profile mapping. Proposed save sequence: validate the complete proposed configuration, review security-sensitive differences, write a new version without overwriting history, atomically update the current pointer, and record the change in audit/history. Handle failed pointer updates and recovery explicitly.

## Verification

Test ordering, provenance, collection semantics, invalid or unsupported schemas, circular includes, traversal/symlink rejection, inaccessible scopes, concurrent edits and failed writes. Confirm an agent/run override cannot escalate permissions. Reopening the app must produce the same effective configuration from the same versioned files.
