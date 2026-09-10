# Immutable requirements and traceability

Status: requirement storage/resolution implemented and validated; native editing/review, deterministic executable validation and traceability services implemented. Source: [final architecture](final-architecture.txt), sections 13–16.
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

`WorkspaceCatalog.requirementStore(in:)` opens a scope-bound local administrative store without creating memory files. Each readable requirement ID permits lowercase ASCII letters, digits and internal hyphens, up to 96 bytes. Storage is `Memory/Requirements/<id>/requirement.vN.json` plus `current.json` inside the selected project. Versions hold scope, schema/version identity, publication ancestry/fingerprints, UTC creation time and structured content. Content includes status, description, preconditions, rules, acceptance/validation descriptions, nested expected behavior, environment IDs, inert source references and a required change reason. Decimal numbers preserve large integer values. Validation-rule descriptions remain inert; typed executable rules use the separate field described below.

Preparation returns an exact in-memory proposal and writes no authoritative files. The native caller must review that proposal before calling `publishReviewed`; cancellation, expiry after five minutes, use by a different store, payload substitution, duplicate use and a changed base reject publication. A store retains at most 16 pending reviews. This is a trusted local administrative API, not a model/mobile tool or a replacement for runtime policy authorization. Native review UI is implemented in P2-02; runtime exposure remains separate.

Publication exclusively creates a new version before atomically replacing the pointer. A version left behind by an interrupted pointer update remains an orphan: later publication skips its number and links to the last committed version. Ordinary resolution and explicit history never silently adopt it. Fingerprints link the typed historical content, detecting inconsistent edits along the committed chain; they are consistency checks, not signatures authenticating files against the local machine owner.

The pointer identifies the latest published version and the active version. Draft publication retains the prior active decision; retirement clears it, including when later drafts exist. A later active publication reactivates the requirement. `resolve` defaults to latest active; latest published and historical versions require explicit selections. An optional environment filter excludes requirements that do not apply to that environment. Native administrative `list` includes draft/retired heads and pages by stable ID, with up to 100 results per call.

Boundaries: each version fits 256 KiB; committed history is bounded to 1,024 versions and 16 MiB, with capacity checked before publication. Expected JSON behavior has bounded depth/nodes/collection sizes; strings and lists have explicit limits. Duplicate JSON keys, invalid pointers, missing committed versions, wrong scope/ownership, symlinks and multiply linked files fail closed. Existing file-descriptor storage and catalog locking provide the filesystem and concurrent-edit boundary. See [validation](../Development/p2-01-validation.md).

## Native requirement review (P2-02)

Open Requirements from a project or use Command-K → Manage Requirements. The scoped browser shows published records, latest published and active versions separately, and explicitly selected immutable history. Edit Latest Version always uses the latest loaded published content, even when viewing older history. The store rejects a changed base at review/publication.

The editor supports ID, status, description, required change reason and configured project environments. Advanced JSON edits preconditions, rules, acceptance/validation descriptions, expected behavior and references with the same bounded validation. Applying JSON changes only the draft. Review shows exact before/after values for all changed fields; Create vN publishes that exact proposal. Cancel preserves authoritative files. Unavailable storage and configuration diagnostics are distinct from an empty collection.

Native actions remain outside scrolling content; project actions wrap in compact windows. Mac model, layout and UI tests cover cancellation, stale/foreign proposals, JSON errors, history after relaunch, retirement/reactivation and environment retention. See [P2-02 validation](../Development/p2-02-validation.md).

## Deterministic executable rules (P2-03)

`executableValidationRules` is an optional list separate from human-readable `validationRules`. Existing content omits it and retains its canonical fingerprint. Each typed rule has schema version 1, a unique readable ID, at most 16 path components and a supported operation. Add it through Advanced JSON and review the resulting field diff before publication. For example:

```json
"executableValidationRules": [
  {
    "schemaVersion": 1,
    "id": "closed-state",
    "path": [{"key": {"_0": "state"}}],
    "operation": "equals",
    "expected": "closed"
  }
]
```

A path component is a literal object `key` or zero-based array `index`, encoded by the shared Codable enum; an empty path selects the entire observation. It never resolves a filesystem path. Supported operations are `equals`, `notEquals`, `exists`, `absent`, `minimum`, `maximum`, `contains` and `type`. Numeric bounds require exact Decimal operands. Contains supports array membership and text substrings. Type operands are `null`, `boolean`, `number`, `text`, `array` or `object`. Exists/absent omit `expected`; explicit JSON null is a valid equality operand and differs from an omitted operand. Unknown operations/schema versions, invalid operands, duplicate rule IDs and excessive paths fail validation before publication.

`RequirementValidator` reads the exact scope-bound store and defaults to latest active; `historicalVersion` is an explicit reproduction choice. Observations carry project/environment identity, source and capture time, plus run/agent identity when applicable. The resulting report preserves the resolved requirement version/fingerprint, rule, observed value and deterministic result. It performs no network or company-data collection. Reports remain in memory; future adapters must redact before storing or displaying evidence.

Absent evidence, incompatible traversal/comparison and zero executable rules produce unavailable results. An explicit existence predicate can fail on a missing path in available structured evidence. JSON null remains observed data. Aggregate status is unavailable when any rule is unavailable, otherwise failed when any predicate fails, otherwise passed. Individual failures remain visible even when other evidence is unavailable; these results do not themselves register a defect. See [validation record](../Development/p2-03-validation.md).

## Reviewed traceability (P2-04)

Project-scoped automated-test, manual-test, bug, documentation and workflow identities can carry reviewed requirement links. `prepareTrace` resolves each ID to latest active unless a historical version is explicitly supplied. `publishReviewedTrace` revalidates exact requirement fingerprints and the prior link record under the catalog lock; `cancelTrace` changes no files. The candidate contains title, environment, change reason and archive state for review. Tokens expire in five minutes and cannot transfer between stores or be replayed.

Current link metadata lives in `Memory/Traceability/<kind>/<id>.json`; reviewed updates atomically replace that record with a higher revision. This is separate from immutable requirement files. IDs are inert readable slugs; links do not execute tests, open external records or create bugs. Native relationship management is implemented in P2-10c below.

`resolveTrace` uses current active behavior for ordinary reruns while retaining creation references. Set `reproduceLinkedVersions` explicitly for historical reproduction. Both paths validate stored fingerprints. `impact` reports saved and active versions, environment applicability and potentially stale/unavailable status, with affected counts for each subject kind. Archived relationships are excluded. Draft-only changes preserve current status; retirement or excluded environments become unavailable. A stale link means review is needed, not proof that the linked test is wrong.

The store supports up to 64 requirement links per record. Impact scans are bounded to 1,000 records and 16 MiB and fail explicitly beyond those limits. All operations revalidate ownership and use the same filesystem lock and descriptor safety boundary as requirement storage. See [P2-04 validation](../Development/p2-04-validation.md).

## Native traceability surface (P2-10c)

The project Traceability action and command palette open a native browser with title/subject/requirement search, kind/environment filters, archive visibility and paginated current link records. New Links and Edit Links prepare an exact before/after review. Ordinary links resolve latest active at review; an explicit historical choice records the requested version. Publication revalidates the base record and requirement fingerprints. Normal inspection still defaults to currently active behavior, while the historical toggle shows the exact recorded requirement content.

Impact can be inspected directly by requirement ID even without a standalone trace record. Standalone trace links and nonarchived Bug Registry associations are displayed separately, preserving each bug association's role and recorded version. Each store query uses the catalog lock and rejects scope or integrity failures; the two reports are consecutive reads, not a promised combined transaction. Review Bug opens a same-project editor using the displayed revision; concurrent changes fail publication. No coverage association claims a test ran or passed.

Trace browse scans and Bug Registry impact queries fail explicitly when their bounds are exceeded. Missing/corrupt references do not become an empty success. Native review and displayed content use centralized redaction. See [validation](../Development/p2-10c-validation.md) for native UI, Mac and iPhone coverage.
