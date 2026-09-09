# Extension development, local CLI and CI

Status: planned design. Source: [final architecture](final-architecture.txt), sections 155–157.
<!-- Source sections: 155,156,157 -->

Do not build a public marketplace before the product requires it. Maintain boundaries that can later support packages contributing plugins, MCP definitions, agents, skills, workflow nodes, scenario runners, database drivers and importers. Every extension still uses workspace scope, policy, secrets and audit.

## Contribution contract

An extension declares identity/version, capabilities, configuration schema, required permissions and supported inputs/outputs. Proposed lifecycle includes validation, enable/disable, health and cleanup. Loading an extension must not automatically authorize all requested capabilities or execute unreviewed setup scripts.

| Addition | Implementation and verification responsibilities |
| --- | --- |
| Agent / skill | Validated scoped definition/references, effective instructions, limits, versioning and eval fixtures |
| Plugin | Normalized capabilities, lifecycle/auth, Keychain references, diagnostics, allow/approval/deny and isolation tests |
| MCP adapter | Supported transport/discovery, scoped tools/resources/prompts, lifecycle, cleanup and failed-health tests |
| DB driver | Safe parameters, query classification/policy, scoped credentials, cancellation and denial tests |
| Workflow node | Typed input/output, deterministic validation, events, retries/timeouts/cancellation, cleanup and lock behavior |
| Scenario runner / importer | Declared supported formats, unsupported-feature errors, secret handling, provenance and migration/identity tests |

Do not create broad extension interfaces without a real implementation need. Concrete contracts and compatibility versions belong in the corresponding package and its tests.

## AgentDesk CLI

A later small local `agentdesk` CLI exposes selected runtime functions such as run a saved scenario, run an agent with project/input, list active runs or search bugs. It is separate from Codex CLI. Reuse the application runtime and policy rather than duplicate business rules in command handlers.

Define stable exit statuses, structured output, explicit scope/environment arguments and cancellation semantics. A CLI invocation must not silently choose a company or production environment. Avoid treating unknown commands as arbitrary shell input.

## CI invocation

Selected scenarios can later be triggered through the local runner/CLI from systems such as GitLab CI. Expose a narrowly scoped execution surface, not the entire desktop app or broad machine credentials. Define identity, permissions, secrets provisioning, result artifacts, concurrency and cleanup before enabling CI access.

Verify CLI/UI policy parity, wrong/missing scope, machine-readable errors, interrupted runs, resource limits and least-privilege CI fixtures. CI output must follow the same redaction and artifact-retention rules.
