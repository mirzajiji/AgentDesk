# Git integration and change review

Status: P1-12c implements internal read-only Git snapshots, dirty-baseline comparison and sanitized text diff previews. P1-13a adds the native repository registration service and durable read-only bookmark lifecycle. Native picker/review UI and commit/push/merge policy flows remain later work. Source: [final architecture](final-architecture.txt), sections 71, 148 and 154.
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

## Implemented capture contract

`GitRepositoryCapture` is an internal Mac actor. An already authorized caller supplies the selected repository root and a `ContentRedactor` bound to the exact project/environment/run. It exposes baseline capture and subsequent comparison, with one operation in flight. Capturing does not grant filesystem access or execution authority, and does not register a repository in the UI. The coordinator and native registration flow must supply the authorized mapping.

The adapter locates Apple's Git binary inside standard Xcode or Command Line Tools installations, then uses fixed argument arrays and a constructed environment. `/usr/bin/git` is an `xcrun` shim that refuses App Sandbox; the actual Git binary runs directly and still inherits the main app's sandbox. Missing supported installations produce an explicit unavailable-tool error. Its only Git operations are local config parsing, index flag inspection, porcelain-v2 status and immutable blob reads. It never invokes Git diff drivers, writes the index, creates commits, cleans files or accesses a remote. Global/system config and attributes are disabled; local config is parsed with `--no-includes` from outside the repository before it is used. Include directives, extensions/partial-clone settings and alternate object stores are rejected. Filters, fsmonitor, hooks, automatic maintenance, optional index locks and lazy fetches are disabled. No inherited `GIT_DIR`, custom index, executable helper, pager, credential helper or pathspec environment is accepted.

The selected directory itself cannot be a symlink. Authorized ancestor aliases such as macOS `/var` resolve to a canonical root, which is pinned by device/inode and revalidated. Descriptor-relative inspection rejects links and special files in Git metadata, and rejects hardlinks or symlink traversal when reading working files. A working-tree symlink may be identified and compared by its link bytes; its target is never opened. Unexpected metadata changes during capture fail visibly.

Status uses porcelain v2 with NUL separators, retaining staged/unstaged status, additions, deletions, renames, unmerged entries and untracked paths. Spaces, tabs, newlines and leading dashes in filenames remain unambiguous. Non-UTF-8 paths, traversal, duplicate entries and malformed records are refused. An unborn repository has an explicit missing HEAD; it is not reported as an error or assigned a fabricated commit. Assume-unchanged and skip-worktree index flags are rejected because they can hide actual filesystem changes.

Each capture performs two matching observations of status and relevant working bytes and checks Git metadata stability across the observation window. Branch, HEAD or configuration changes after the baseline invalidate that baseline. This is an observed window, not an atomic filesystem snapshot or a lock against other processes; actions must still revalidate their inputs when they execute.

## Baselines, previews and publication

Baseline evidence records all current dirty entries. Later records distinguish unchanged preexisting edits, changes since the baseline, newly changed paths and entries no longer appearing in status. The last category can mean restoration, removal or new ignore rules; it does not invent a cause. Current bytes for those baseline paths are observed in both passes, preserving a preview of restored tracked files and removed untracked files. Renames retain the original path. None of these labels proves which process or person made an edit.

Previews distinguish **HEAD → index**, **index → working tree**, and **run baseline → working tree**. Text comes directly from bounded immutable Git blobs and scoped working-file reads. Each complete source text is sanitized before the deterministic line comparison, so a multiline secret cannot leak after diff prefixes split it across lines. Path labels use standard JSON escaping and the final preview crosses the redactor again. If different raw contents become identical after redaction, the preview says so instead of showing a false unchanged result. Classification propagates to the final evidence.

The output is scoped `RedactedText` for snapshot JSON and a unified text preview. These can be published through `EvidenceStore` as observed repository artifacts; the integration test stores both, reopens them and checks recovery. Raw file digests and local configuration remain in memory only; the snapshot retains HEAD commit identity as provenance. Redacted previews are for review and cannot authorize or serve as an apply-patch operation.

Current limits are explicit: ordinary repositories with an in-root `.git` directory; 128 current changed paths; 256 KiB of captured source text per observation and per command output; 64 KiB per file/blob; 1,024 lines per compared text; metadata traversal of at most 32,768 entries and depth 64; at most eight configured filter drivers; a 30-second capture deadline. The snapshot and combined diff each must fit the redactor's 256 KiB input bound. Exceeding a hard bound fails rather than returning a silently truncated snapshot. Files beyond the per-file bound, binary files, directories and symlinks have explicit unavailable-preview states; large-file comparisons remain indeterminate. Submodule contents are not inspected, and linked worktree roots, bare repositories and unsupported repository formats are refused. Native picker/review UI, richer large/binary review, worktree support and all Git mutations remain later tasks.

Behavior was checked against Apple Git 2.50.1 (Apple Git-155) and its installed `git`, `git-status` and `git-config` manual pages. See [capture validation](../Development/p1-12c-validation.md) for exact test counts, commands and native results.

## Implemented native registration service (P1-13a)

`ProjectRepositoryRegistry` is a trusted local administrative service. Every operation verifies workspace/project membership in `WorkspaceCatalog`. An explicit native folder selection can register one ordinary Git root per project. A fixed read-only preflight validates Git configuration and the actual worktree root, with a ten-second deadline and the same safe environment as capture. It never follows repository includes, invokes hooks, accesses remotes or writes the repository.

Each registration has a UUID, revision, canonical path and physical scope/device/inode resource identity. Its private machine-local JSON record also contains opaque operating-system bookmark data. Store these records in a private application-support directory separate from portable workspace configuration; exclude them from backups, artifacts and mobile responses. Public metadata cannot serialize or expose the bookmark. Files use bounded duplicate-key-rejecting JSON, 0600 exclusive temporary publication, descriptor-relative access, no-follow/single-link checks and directory identity validation. Stale revisions or invalid records fail without replacing prior data.

Bookmarks request read-only security scope and resolve without UI. Missing, stale, moved or replaced roots require explicit reselection; the service does not silently adopt another directory or renew a stale mapping. `RepositoryAccess` retains the successful OS grant and a shared project lease. Multiple readers can hold access, while replacement/removal needs an exclusive lease. `NativeRunService` retains access through coordinator shutdown and process cleanup. Removal deletes only the registration record and never the selected repository.

The main Mac app declares app-scoped bookmark support following [Apple's bookmark entitlement documentation](https://developer.apple.com/documentation/professional-video-applications/enabling-security-scoped-bookmark-and-url-access). Its existing App Sandbox and user-selected read-only boundary remain in force. Creating/resolving a bookmark inside the app container is covered by a real native test; that does not establish external-folder selection or access after app relaunch. Those UI acceptance cases remain P1-13c. The registration service does not yet store editable remote/default-branch/role metadata; capture records observed branch/HEAD, and richer repository configuration remains later scope.

Prepared native runs persist the selected directory and, when registered, exact registration UUID/revision in the redacted input snapshot. Bookmark data never enters run evidence. Historical records without this location field are left unchanged. See [registration validation](../Development/p1-13a-validation.md).
