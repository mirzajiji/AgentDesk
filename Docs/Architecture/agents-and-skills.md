# Agents, templates and skills

Status: project agent creation/editing, native instruction editor, versioned snapshots, templates and archive/restore implemented in P1-06a; workspace/project instruction sets and effective instruction previews are added in P1-06b1; P1-06b2 implements profile composition, environment constraints and output schemas; P1-06b3 adds scoped versioned skill bundles, native editing and pinned agent references. See [P1-06a native validation](../Development/p1-06a-validation.md). Source: [final architecture](final-architecture.txt), sections 18, 19 and 21.
<!-- Source sections: 18,19,21 -->

An agent definition combines task-specific instructions and explicitly permitted capabilities. It is configuration consumed by the runtime, not a separate security authority.

## Agent definition

Store ID/name/description, workspace and project scope, enabled state, execution profile, instruction and skill references, knowledge selection, allowed tools/plugins/MCP/databases, permissions, environments, output schema, maximum steps, timeout, working directory, approval/delegation policy and tags. Validate relationships and references before saving and again when producing a run's effective context.

Built-in QA templates include QA Manager, Requirement Analyzer, Test Designer, Automation Engineer, API Tester, Database Analyst, Failure Analyzer, Bug Writer, Documentation Agent and Release Agent. A general assistant and investigation templates can support onboarding. Templates are starting points; they do not automatically connect accounts or grant tools.

Use deterministic code for tasks that do not need reasoning. Avoid creating an agent for every comparison, parsing step, calculation or subprocess launch.

## Skill bundle

A skill contains `skill.json`, `instructions.md`, and optional examples/scripts. Metadata describes identity, purpose, when to use it, inputs/outputs, required instructions/tools/permissions and tags. The UI manages the full bundle with source visibility and validation.

Scripts and example references must stay within the authorized bundle/workspace boundary. Installing or selecting a skill does not grant its requested permissions. Resolve requested capabilities through the same policy used by agents and workflows.

## Runtime and editing behavior

The agent editor exposes general properties, instructions, execution, tools, skills, knowledge, plugins, MCP, databases, permissions, outputs, tests and versions. Keep inactive/unimplemented capabilities clearly unavailable. Effective-prompt preview must list actual selected sources and omit secrets.

Version critical configuration, record exact versions on runs, and review material instruction/permission changes. Deleting or disabling an agent must have defined behavior for queued and active runs; do not silently mutate the configuration snapshot of an already-started run.

## Verification

Test validated CRUD/reopen, template instantiation without privilege grants, invalid references and output schemas, include cycles, secret exclusion, cross-workspace agent/skill denial, disabled-state handling and preservation of run configuration versions. See [configuration](configuration.md), [workflows](workflows.md) and [agent evals](testing-and-coverage.md).

## Initial agent editor and storage

On Mac, open a project's **Agents** panel, create an agent from one of eleven templates, and edit its name, description, instructions and Codex execution profile. All templates request read-only access and use the provider's default model unless the user configures an override. The editor supports disabling, archiving and restoring agents. These settings do not run Codex or grant access; runtime policy enforcement arrives before execution is exposed.

`WorkspaceCatalog.agentStore(in:)` validates workspace/project membership and returns a `ProjectAgentStore` bound to that exact project. Every store operation checks the requested scope. Configuration lives below `Projects/<project UUID>/Agents/<agent UUID>/`: `current.json` selects a revision under `Versions/<revision>/`, with readable `agent.json` and `instructions.md`. Every save, archive and restore creates a new immutable revision. Old files remain unchanged. New versions are staged and published atomically before the current pointer changes. An unpublished version left by a failed pointer update is preserved and skipped when allocating the next revision; it is not automatically made current.

Saves require the expected current revision, so stale editors cannot silently overwrite a later save. Names are normalized and unique among active agents in their project. Archived names may be reused; restoring an archived agent fails if an active agent now has its name. Archived agents cannot be edited until restored. Queued/active-run handling is deferred until runs exist and must use frozen agent snapshots.

The catalog's advisory lock now opens a separate file description for each operation. This matters because several project-agent actors can share a catalog root: locking a shared descriptor alone would not serialize those actors. Tests cover both concurrent stores and reentrant attempts on a shared directory handle.

Agent profiles contain a Codex model override, read-only/workspace-write request, maximum steps, timeout and optional output-byte ceiling, environment allowlist and output schema. Inputs are bounded and validated; instructions must be nonempty UTF-8 text no larger than 64 KB. The basic native editor preserves advanced fields; advanced controls remain pending. The effective configuration composer validates the new constraints and the internal provider enforces final output schemas. Native skill creation, editing, attachments, archive/restore and agent selection are available; external bundle import and app run launch remain pending. See [configuration composition](configuration.md) for exact rules and limits.


## Implemented skill bundles and native editing

On Mac, open **Agents → Skills → New Skill**. Choose the current project or its workspace, enter a name, description and instructions, and declare any requested permissions. The scope is fixed after creation. The Attachments tab adds, edits, removes and previews example documents or script text. Example names end in `.md` or `.json`; filenames cannot contain directories. Saving preserves the complete bundle as a new version. Scripts remain nonexecutable files and this UI has no Run Script command. Archive/restore also creates versions; disabling a skill prevents future resolution while preserving its contents.

Open **Edit Agent → Skills** to attach a skill. The agent records exact workspace/project scope, skill UUID and revision. Existing selections stay pinned when a skill is edited. **Use version N** explicitly updates a pin; removing a reference does not delete the skill. Disabled/archived skills cannot be newly selected, and an existing unavailable/missing reference can be removed. Shared workspace skills are available only to that workspace's projects. Each scope has its own active-name uniqueness check.

**Review Instructions** appends selected skill instructions after the agent, in reference order, showing each source title, exact version, workspace-relative file and SHA-256. Permission requests are listed separately. Examples and scripts are reviewable in the skill editor and are not automatically injected into the prompt or executed. The internal Codex adapter continues to disable ambient host skill discovery; only deliberately composed AgentDesk instructions enter its request. Attaching a skill cannot change the agent access mode, model/environment constraints, policy documents, workspace lock or approval authority.

`WorkspaceCatalog.skillStore(in:)` returns `ProjectSkillStore` bound to an authorized project. A workspace skill lives at `Skills/<skill UUID>/`; a project skill lives at `Projects/<project UUID>/Skills/<skill UUID>/`. Each contains `current.json` and `Versions/<revision>/skill.json`, `instructions.md` and the selected `examples/` or `scripts/` files. Manifest metadata binds exact ownership, ID, revision, enabled/archive state, permission requests, timestamps, fixed instruction filename, derived attachment filenames and fingerprints for every text file.

The store validates paths and scope before opening anything. Reads are descriptor-relative, reject symlinks, nonregular files and hardlinks, and verify text fingerprints. Unknown manifest/scope/reference/file fields, duplicate JSON keys, unsupported versions, invalid file kinds and malformed content fail closed. Writes use staged directories, atomic publication, the catalog root lock and an expected current revision. Failed publication preserves prior versions; orphan versions are skipped when allocating the next revision and are not automatically made current.

Limits: 16 references per agent, one revision of a given scoped skill per agent, 16 attachments per skill, 100 characters per display name, 100 ASCII bytes per attachment filename, 4 KiB description, 64 KiB UTF-8 instructions or attachment text, 256 KiB combined text per bundle, 32 KiB manifest and revisions up to 1,000,000. NUL, traversal, absolute paths, hidden/parent-like names, case-colliding attachments, duplicate permissions and oversized content are rejected. Agent publication also checks its entire encoded manifest against the 64 KiB read limit so expanded references/schemas cannot create an unreadable agent version.

Agent saves resolve every selected reference before publication. Instruction preview rechecks both the current skill state and the pinned version: disabling/archiving the current skill blocks old pins for new previews, while restoring it permits a still-enabled historical pin. Already frozen run snapshots need coordinator handling; they are not silently changed. Basic metadata and permission declarations are implemented. Rich input/output/tool schemas, tags, external import/discovery and executable workflow integration remain later platform/UI work. The synthetic bundle used in unit tests includes an evidence-review instruction, example Markdown and a script that would create a marker if executed; the marker is never created.

See [skill validation](../Development/p1-06b3-validation.md) for native acceptance and [configuration](configuration.md) for separate execution constraints and policy snapshots.
