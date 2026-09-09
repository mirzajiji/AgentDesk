# Configuration composition and versioning

Status: workspace/project instruction sets and effective instruction preview implemented in P1-06b1; native acceptance passes; see [validation](../Development/p1-06b1-validation.md). Effective execution-profile overrides, environment constraints, skills, workflow/run layers and output schemas remain later tasks. Source: [final architecture](final-architecture.txt), sections 8, 10 and 131–133.
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

## Implemented instruction sets

Open a project's **Agents → Shared Instructions** panel. Choose Project for guidance limited to that project or Workspace for guidance inherited by every project in that same workspace. Each set contains named Markdown documents, an ordered list of root documents, and explicit same-set include references. The editor adds/removes documents, selects direct roots and includes, and validates before saving. A scope switch is disabled while edits are unsaved. Removing a document still referenced by another file is rejected; clearing the entire set creates an empty revision while preserving history.

Each scope stores `Instructions/current.json` and `Instructions/Versions/<revision>/instructions.json`, plus `<instruction UUID>.md` files. The manifest declares exact scope, revision, document identity/title/derived filename, include IDs and roots. UUID-derived file paths are checked again on read. Reads use existing descriptor-relative no-follow/regular-file checks. No include is an arbitrary filesystem path, URL, environment variable or Keychain reference. A reference must resolve within the same set; project files cannot read another project through includes.

The store writes complete revisions before publishing the current pointer, checks the expected prior revision and preserves orphan versions on retry. Workspace sets are deliberately shared only among that workspace's projects. Project sets remain project-specific. The catalog validates membership when opening the store and every operation revalidates its requested identity against the workspace/project records.

**Review Instructions** loads one frozen preview in this order: built-in global safety text → selected workspace files → selected project files → the selected agent revision. Includes expand before their referring document; repeated references contribute only once per scope, in first-use order. Unselected documents are omitted from composed text. All documents, including unselected ones, are checked for invalid references/cycles. Each preview source records its layer, title, revision, relative filename, exact text and SHA-256 fingerprint. The global source is nonconfidential bundled text, not a scan of user or other-workspace files.

Limits are 64 documents/roots per set, 64 includes per document, 32 include edges in a chain, 64 KiB of UTF-8 text per file and 256 KiB of text per set. Missing files, malformed manifests, scope mismatches, unsupported versions, symlinks, duplicate IDs/roots, cycles and stale saves fail without silently replacing current files. Cancellation and write failures leave previous committed data intact; an unpublished complete revision may remain for recovery.

This preview does not start Codex or grant authority. It does not yet apply workflow/run layers, user-editable global settings, skill bundles or profile overrides. Execution will record the frozen configuration and cross the separate policy boundary before any provider call. Native shared-instruction editing and preview are Mac-only.
