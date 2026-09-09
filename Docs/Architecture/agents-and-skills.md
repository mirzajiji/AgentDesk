# Agents, templates and skills

Status: project agent creation/editing, native instruction editor, versioned snapshots, templates and archive/restore implemented in P1-06a; workspace/project instruction sets and effective instruction previews are added in P1-06b1; profile composition, skills, environment constraints and output schemas follow in P1-06b2/b3. See [P1-06a native validation](../Development/p1-06a-validation.md). Source: [final architecture](final-architecture.txt), sections 18, 19 and 21.
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

Agent profiles currently contain a Codex model override, read-only/workspace-write request, maximum steps and timeout. Inputs are bounded and validated; instructions must be nonempty UTF-8 text no larger than 64 KB. Advanced capabilities remain pending and are not shown as usable settings. P1-06a alone does not compose instructions, install skills, execute output schemas or start live Codex runs. See [configuration composition](configuration.md) for the subsequent shared-instruction implementation.
