# Workspaces and company isolation

Status: typed identities, descriptor-bound reads, and local workspace/project creation, listing, renaming and reopening are implemented (P1-02/P1-03). Runtime policy and workspace locks remain planned. Source: [final architecture](final-architecture.txt), sections 6, 7, 9 and 128.
<!-- Source sections: 6,7,9,128 -->

Each company receives an isolated workspace containing projects, agents, instructions, skills, plugins, MCP definitions, databases, environments, workflows and repository registrations. Example company names in the specification are illustrations; do not seed real company content or connect accounts automatically.

## Scope model

Every operation carries `WorkspaceID` and `ProjectID`, plus `EnvironmentID`, `RunID` and `AgentID` where appropriate. IDs are stable identities rather than display labels. Workspace names and directory names must not serve as authorization evidence.

Proposed enforcement boundary: resolve an authorized workspace context once at each application/service entry point, then require that context on storage and capability calls. Validate the relationship between all child IDs and their workspace/project before accessing resources. Scope checks must also apply when reading by a globally unique run or artifact ID.

Company A must not access Company B's code, tickets, requirements, prompts, memory, credentials, logs, MCP/plugin/database results, artifacts, traces, runs or evidence. Each persistence query and filesystem operation needs a scope predicate or a store already bound to the authorized scope. UI filtering is insufficient.

## Filesystem layout

Within a workspace, `workspace.json` identifies it; `Projects/<project>/project.json` identifies each project. Project subdirectories hold requirements, validation/business rules, tests, bugs, evidence, decisions, documentation and database knowledge. Other workspace-level directories hold agent/skill/workflow/integration definitions and repository registrations.

Configuration is human-readable. Operational records go in SQLite; credentials remain in Keychain. Source-control fixtures must be synthetic. Real runtime workspaces and operational data are excluded from the AgentDesk source repository.

## Safe path resolution

Reject unexpected absolute paths, traversal components, invalid names, escaped encodings after normalization, sibling-prefix matches and symlink escapes. Compare path components rather than string prefixes. A user-selected external repository is an explicitly registered resource; it is not automatically trusted because a path exists.

`WorkspaceFileSystem` anchors reads to an open workspace directory. Every requested path component uses descriptor-relative, no-follow opens; only bounded regular files with one hard link are accepted. `WorkspacePath` rejects traversal, absolute paths, percent encoding, colons and control characters. Only the caller-authorized container is canonicalized (including macOS `/var` aliases). Reads check cancellation and file growth. An opened root cannot be redirected by replacing its original path with a symlink. This storage boundary does not establish project membership or grant policy approval; those checks belong to their services. Configuration writes now use private staging files, bounded data, file synchronization and atomic descriptor-relative publication. Creation refuses to replace an existing destination; renaming validates the existing regular file before replacement. The catalog holds a nonblocking advisory lock across validation and publication so cooperating windows/processes cannot create duplicate names concurrently.

## Human context switching

Persistently display workspace/project/environment identity. For external or destructive actions, repeat the concrete workspace, project, environment and resource in review. A visual workspace lock helps prevent operator mistakes but supplements, rather than replaces, code enforcement.

Verification must include two-workspace fixtures with deliberately overlapping names, IDs supplied from the wrong scope, nested/sibling paths, traversal, symlink escape, unauthorized search, cross-workspace event subscription and scoped error responses that do not leak the other company's content.

## Implemented local catalog

`WorkspaceCatalog` stores schema-versioned `workspace.json` and `Projects/<project UUID>/project.json` below UUID workspace directories. It validates the identities against their containing directories and checks project membership on every read/edit. Names are trimmed, Unicode-normalized, bounded and compared case-insensitively within their parent; projects in different workspaces may share a display name. Invalid or newer-version configuration fails closed and stays on disk for recovery.

The Mac browser creates and renames workspaces/projects, selects their scope, and reopens the selected workspace on relaunch. Storage is the application's Application Support directory under `AgentDesk/Workspaces` (inside the app container when sandboxed). No company fixtures are seeded. Debug UI tests use a separate UUID-named storage area and preferences suite, never a data-reset flag or caller-provided arbitrary path.

Creation assembles an unpublished `.new-<UUID>` directory, then publishes it atomically. Failed operations clean up their known staging contents. Staging left by process termination is ignored and preserved for recovery. The advisory catalog lock coordinates AgentDesk writers; it does not protect against malicious processes with equivalent filesystem authority. Atomic visibility is provided; a power-loss durability guarantee and automated abandoned-staging recovery are not claimed. Deletion/archive, importing arbitrary folders, repositories and runtime authorization remain later features.
