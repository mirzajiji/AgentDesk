# Projects, environments and onboarding

Status: local project creation, validation, renaming, listing and reopening implemented; repository registration and the full onboarding wizard remain planned. Source: [final architecture](final-architecture.txt), sections 143 and 147; workspace structure is detailed in [workspaces](workspaces.md).
<!-- Source sections: 143,147 -->

A project groups repositories, environments, connections, requirements, test assets, bugs and agent/workflow scope inside one workspace. Creating a project establishes its identity and human-readable configuration before optional integrations are configured.

## Onboarding flow

The full wizard covers project details, repositories, environments, databases, plugins, MCP, requirement/documentation import, Postman collections, agent templates, permissions, connection tests and completion. Steps remain editable later. Optional integrations can remain unconfigured; the UI must not label them connected just because a configuration file was saved.

The initial Phase 1 slice implements project name/identity, workspace membership and local configuration storage. Repository registration follows separately. Later wizard steps should appear only when their implementation exists. Distinguish partial setup from a ready-to-run project and explain missing prerequisites for a selected action.

## Repository registration

Store each repository's local path, remote reference, default branch, and role/purpose, such as product backend or automation. Repositories are explicit project resources. Codex must receive the selected registered working directory rather than guess among company repositories.

At registration and before execution, verify existence, identity, workspace ownership and current repository state. Treat symlinked paths and changed remotes as changes requiring renewed validation. A path label or a previously successful access check must not grant indefinite authority.

## Environments and connections

Environment identity accompanies every run, query and result. A project's selected development, test or production environment must be visible. Secret values are resolved from scoped references only at the authorized execution boundary. Connection duplication must not silently reuse credentials or broader permissions from another workspace.

## Validation

Exercise create/reopen/edit, duplicate names, invalid IDs, incomplete configuration, two projects with similar paths, missing repositories, wrong remotes, unavailable environments and onboarding cancellation. Verify partial configuration is recoverable and never creates an unexpected external side effect. The [repository policy](repositories.md) governs execution-time Git checks.
