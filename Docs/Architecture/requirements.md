# Immutable requirements and traceability

Status: requirement storage/resolution implemented and validated; native editing/review implemented; executable validation and traceability remain planned. Source: [final architecture](final-architecture.txt), sections 13–16.
<!-- Source sections: 13,14,15,16 -->

Requirement content is immutable after creation. A behavior change creates a new version and advances a current pointer; it never rewrites a prior version.

## Storage contract

Each requirement has its own directory containing `requirement.v1.json`, subsequent version files and `current.json`. The current pointer identifies the requirement, current version and current file. Each version records identity, version, status, superseded version, description, preconditions, rules, acceptance criteria, validation rules, expected behavior, environment scope, references, change reason and creation time.

The supplied examples define intent, not a finalized JSON Schema. Implementation must add schema/version validation, workspace/project ownership and safe resolution. Reject pointers to nonexistent files, mismatched IDs or versions, inaccessible scopes or arbitrary filesystem paths.

## Editing and publication

Show current v3 alongside proposed v4 and a meaningful diff/change summary. Saving creates v4 while retaining v3. Cancel leaves all authoritative versions untouched. Review security and expected-behavior changes through the application's authorization rules.

Proposed concurrency rule: an editor records the base version and publication fails with a conflict if current changed in the meantime. Serialize version allocation and immutable file creation within the scoped store; atomically update the pointer only after a complete validated version exists. Define recovery for a created version whose pointer update failed.

## Resolution

New tests, regression analysis, expected results, bug investigation, validation and ordinary reruns resolve the latest active version. A numeric newest draft or retired version is not automatically the latest active requirement. Historical versions require an explicit reproduction or review choice.

Tests and scenarios record exact requirement IDs and versions. When v5 replaces referenced v4, mark dependent records potentially stale and show impact links to manual tests, automation, bugs, documentation and workflows. Staleness indicates review is needed; it does not prove the test is wrong.

## Verification

Create v1 and v2; byte-compare v1 after publication; verify version allocation, active/draft/retired resolution, pointer corruption handling, cross-scope denial, concurrent-edit conflict, historical reproduction, stale-link detection and impact counts. Test interrupted saves and reload behavior without overwriting prior versions.

## Initial store contract (P2-01)

`WorkspaceCatalog.requirementStore(in:)` opens a scope-bound local administrative store without creating memory files. Each readable requirement ID permits lowercase ASCII letters, digits and internal hyphens, up to 96 bytes. Storage is `Memory/Requirements/<id>/requirement.vN.json` plus `current.json` inside the selected project. Versions hold scope, schema/version identity, publication ancestry/fingerprints, UTC creation time and structured content. Content includes status, description, preconditions, rules, acceptance/validation descriptions, nested expected behavior, environment IDs, inert source references and a required change reason. Decimal numbers preserve large integer values. Validation-rule descriptions are not yet executable rules.

Preparation returns an exact in-memory proposal and writes no authoritative files. The native caller must review that proposal before calling `publishReviewed`; cancellation, expiry after five minutes, use by a different store, payload substitution, duplicate use and a changed base reject publication. A store retains at most 16 pending reviews. This is a trusted local administrative API, not a model/mobile tool or a replacement for runtime policy authorization. Native review UI is implemented in P2-02; runtime exposure remains separate.

Publication exclusively creates a new version before atomically replacing the pointer. A version left behind by an interrupted pointer update remains an orphan: later publication skips its number and links to the last committed version. Ordinary resolution and explicit history never silently adopt it. Fingerprints link the typed historical content, detecting inconsistent edits along the committed chain; they are consistency checks, not signatures authenticating files against the local machine owner.

The pointer identifies the latest published version and the active version. Draft publication retains the prior active decision; retirement clears it, including when later drafts exist. A later active publication reactivates the requirement. `resolve` defaults to latest active; latest published and historical versions require explicit selections. An optional environment filter excludes requirements that do not apply to that environment. Native administrative `list` includes draft/retired heads and pages by stable ID, with up to 100 results per call.

Boundaries: each version fits 256 KiB; committed history is bounded to 1,024 versions and 16 MiB, with capacity checked before publication. Expected JSON behavior has bounded depth/nodes/collection sizes; strings and lists have explicit limits. Duplicate JSON keys, invalid pointers, missing committed versions, wrong scope/ownership, symlinks and multiply linked files fail closed. Existing file-descriptor storage and catalog locking provide the filesystem and concurrent-edit boundary. See [validation](../Development/p2-01-validation.md).

## Native requirement review (P2-02)

Open Requirements from a project or use Command-K → Manage Requirements. The scoped browser shows published records, latest published and active versions separately, and explicitly selected immutable history. Edit Latest Version always uses the latest loaded published content, even when viewing older history. The store rejects a changed base at review/publication.

The editor supports ID, status, description, required change reason and configured project environments. Advanced JSON edits preconditions, rules, acceptance/validation descriptions, expected behavior and references with the same bounded validation. Applying JSON changes only the draft. Review shows exact before/after values for all changed fields; Create vN publishes that exact proposal. Cancel preserves authoritative files. Unavailable storage and configuration diagnostics are distinct from an empty collection.

Native actions remain outside scrolling content; project actions wrap in compact windows. Mac model, layout and UI tests cover cancellation, stale/foreign proposals, JSON errors, history after relaunch, retirement/reactivation and environment retention. See [P2-02 validation](../Development/p2-02-validation.md).
