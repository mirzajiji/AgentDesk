# Git integration and change review

Status: planned design. Source: [final architecture](final-architecture.txt), sections 71, 148 and 154.
<!-- Source sections: 71,148,154 -->

Register repositories explicitly with workspace/project ownership, path, remote, default branch and role. Before Codex edits, validate the mapping and capture branch, commit and dirty state. A previously selected repository can change underneath the app and must be checked at execution time.

## Change collection

Collect Git status, changed files and diff, distinguishing additions, modifications, deletions and renames. Preserve the user's preexisting dirty state. Compare with the run's initial snapshot to avoid attributing unrelated preexisting changes to the agent. Do not silently reset, clean or overwrite the user's work to simplify attribution.

Desktop review provides readable file lists and diffs; mobile review is read-only. Large/binary files need clear limitations and artifact references. Handle unusual filenames using machine-readable, unambiguous Git formats rather than whitespace splitting or shell interpolation.

## Repository policy

The product can default to denying modifications on the default branch, allowing a working branch, and requiring approval for commit/push/merge. Show branch, remote, identity, workspace/project and exact reviewed changes for side effects. A changed branch, diff or remote after approval must be revalidated. Preserve remote history and reject unexpected non-fast-forward results.

For development of AgentDesk itself, the user separately authorized personal GitHub commits/pushes with `Mirza Jijieshvili <mirzajijieshvili@gmail.com>`, one tested task per commit, and `codex/` branches. Do not confuse this session authorization with the product's future runtime policies.

## Configuration backup

An optional dedicated local/private Git repository may version agents, skills, requirements, workflows and project definitions. Operational evidence and secrets are excluded by default. Preview the selected files and destination; do not automatically push company configuration to the AgentDesk source repository.

Tests cover dirty starting states, unrelated edits, renamed/deleted/binary files, unusual filenames, scope mismatch, changed remotes, approval invalidation, default-branch denial, rejected pushes and sanitized configuration backup selection.
