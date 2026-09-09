# Configuration composition and versioning

Status: P1-06b1 implements shared instructions; P1-06b2 adds immutable execution settings, project environments, stored policy documents, effective configuration and provider output contracts. See [configuration validation](../Development/p1-06b2-validation.md). Skill bundles and native advanced configuration controls remain later tasks. Source: [final architecture](final-architecture.txt), sections 8, 10 and 131–133.
<!-- Source sections: 8,10,131,132,133 -->

Configuration stays in readable JSON, Markdown and appropriate YAML. The UI edits these files through validated services. SQLite can index or cache configuration but is not its only authoritative copy.

## Effective configuration

Composition order is global → workspace → project → agent → workflow → run. Each resolved value should retain its source, and the user should be able to inspect effective configuration and effective instructions before execution.

Execution merge rules are now defined and tested below. Instruction composition remains separate: prompt text never grants authority. Do not implicitly concatenate credentials, permissions or environment access.

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

The instruction preview does not start Codex or grant authority. Workflow/run instruction layers, user-editable global settings and skill bundles remain pending. Execution configuration has its own composer below. Native shared-instruction editing and preview are Mac-only.


## Implemented execution configuration

`WorkspaceCatalog.executionConfigurationStore(in:)` opens a project-authorized store. Workspace and project settings live at `Execution/current.json` and `Execution/Versions/<revision>/execution.json` beneath their existing catalog directories. Each JSON snapshot contains schema version, exact owner, immutable revision, creation time and its draft. The draft holds settings and an optional policy document; project drafts additionally contain up to 64 named, typed, enabled/disabled environments and an optional default environment ID. Workspace lock is a workspace-only setting. No environment can supply an arbitrary working directory, credential value or infrastructure connection through this API.

Environment definitions include their exact project scope, stable environment ID, kind (development/test/production), constraints and optional environment policy. The selected environment must exist, be enabled and belong to the project. A new project has no implicit environment: preflight must select/configure one. Workspace settings are shared only among that workspace's projects. Agent profiles can additionally restrict environment IDs, bound output bytes and select an output schema. Historical agent JSON without these optional fields keeps its original model/access/step/timeout values; normal edits preserve new fields.

A frozen effective configuration composes bundled global limits → workspace → project → selected environment constraints → agent → optional workflow → optional run settings. The environment stage adds restrictions before the agent layer; its identity/kind cannot be changed by workflow/run settings. Model identifiers are optional configuration strings; nil inherits, and the most specific explicit identifier wins. If any model allowlist exists, the final model must be explicit and present in every allowlist; an unknown provider default cannot bypass the list. Environment allowlists also intersect. Nil means no additional restriction; an empty allowlist denies everything.

Timeout, item/step and combined assistant-output byte ceilings use the smallest value across all layers. Equal limits keep the earliest limiting source. Bundled ceilings are 3,600 seconds, 1,000 provider activities and 262,144 bytes; agent defaults remain 600 seconds and 30 activities. A historical agent timeout up to 86,400 seconds is therefore capped explicitly. A workspace-write request is rejected when any read-only ceiling applies. The current read-only provider also rejects otherwise permitted write intent as unsupported instead of silently changing the request. Network, tools and external effects are not granted by these settings.

An output schema is inherited once selected. Later layers may repeat the same schema or leave it unset; a different schema fails composition. This conservative rule avoids treating a looser child schema as a valid override. The effective result records the exact agent/environment, source layer/revision/settings/fingerprint, winning scalar/limiting-budget origins, policy snapshot and a fingerprint of the complete configuration. It is encodable for a run snapshot; it cannot be decoded into an execution grant. Transient workflow/run settings are supported as data inputs; this does not implement a workflow executor.

Policies are stored at their actual workspace, project and environment levels and validated against those exact identities. Missing policy documents resolve to a stable, versioned deny-all default. Agent/workflow/run settings cannot replace policies or unlock a workspace. The snapshot carries the stored environment kind and workspace lock into the separate policy engine. The coordinator must use that snapshot, authenticate the requester, resolve the actual repository/filesystem resource, freeze instructions and bind the exact action before dispatch. Configuration preview and the internal provider alone do not authorize execution.

The store uses the existing descriptor-relative no-follow reads, regular-file/single-link checks, root advisory lock, expected revision gate and staged atomic publication. Reads are bounded to 256 KiB and reject duplicate JSON keys; settings, drafts, environments and output schemas reject unknown fields. Revision updates preserve history and skip orphan versions. Invalid scope, missing/malformed files, stale saves and cancellation fail without overwriting prior versions. Native editing/preview of these advanced settings, repository directory registration and full run snapshot persistence remain coordinator/UI work.

## Output contract supported in P1-06b2

The schema is real JSON Schema with an explicitly limited vocabulary. Root output must be a closed object; every declared property is required. Nested schemas support closed objects (up to 64 ASCII-named properties), bounded arrays (`items`, `minItems`, `maxItems`, at most 1,000), bounded strings (`minLength`, `maxLength`, at most 65,536 Unicode code points, optional finite string `enum`), bounded 32-bit integers (`minimum`, `maximum`), booleans and null. Schemas have at most 256 nodes, 12 nested edges and 64 KiB encoded size. Unsupported keywords/types, open objects, missing bounds and invalid constraints fail; this is not a full JSON Schema implementation.

Required properties must be present; null differs from absence. Integer values such as `1.0` and `1e2` are accepted when mathematically integral and within bounds. String lengths count Unicode code points, and enum matching compares exact scalars. These semantics follow the [JSON Schema object reference](https://json-schema.org/understanding-json-schema/reference/object), [numeric reference](https://json-schema.org/understanding-json-schema/reference/numeric) and [validation specification](https://json-schema.org/draft/2020-12/json-schema-validation).

The bounded JSON reader rejects invalid UTF-8, malformed syntax, duplicate/equivalent object keys, trailing content, depth over 40, more than 8,192 values and numeric tokens over 64 bytes/28 digits or outside Foundation Decimal's range. Integer comparisons use decimal arithmetic, not binary floating point. These are explicit parser resource limits, including for invalid outputs; they do not promise arbitrary-precision JSON numbers.

Runtime sends the schema as the installed CLI's supported `turn/start.outputSchema` and validates the final answer again after protocol completion and clean process exit. A mismatch produces `invalidOutput` and no completed event. All assistant messages share the configured byte budget. Commentary/intermediate messages remain untrusted observations and may not match the final schema. Schema success checks structure, not factual truth, secret redaction or policy authority; redaction must still run before persistence/display. The installed CLI schema is preserved only in ignored validation output; the public [Codex app-server documentation](https://learn.chatgpt.com/docs/app-server) describes the protocol.
