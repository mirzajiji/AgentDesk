# Agents, templates and skills

Status: planned design. Source: [final architecture](final-architecture.txt), sections 18, 19 and 21.
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
