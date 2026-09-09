# Immutable requirements and traceability

Status: planned design. Source: [final architecture](final-architecture.txt), sections 13–16.
<!-- Source sections: 13,14,15,16 -->

Requirement content is immutable after creation. A behavior change creates a new version and advances a current pointer; it never rewrites a prior version.

## Storage contract

Each requirement has its own directory containing `requirement.v1.json`, subsequent version files and `current.json`. The current pointer identifies the requirement, current version and current file. Each version records identity, version, status, superseded version, description, preconditions, rules, acceptance criteria, validation rules, expected behavior, environment scope, references, change reason and creation time.

The supplied examples define intent, not a finalized JSON Schema. Implementation must add schema/version validation, workspace/project ownership and safe resolution. Reject pointers to nonexistent files, mismatched IDs or versions, inaccessible scopes or arbitrary filesystem paths.

## Editing and publication

Show current v3 alongside proposed v4 and a meaningful diff/change summary. Saving creates v4 while retaining v3. Cancel leaves all authoritative versions untouched. Review security and expected-behavior changes through the application's authorization rules.

Proposed concurrency rule: an editor records the base version and publication fails with a conflict if current changed in the meantime. Serialize version allocation and immutable file creation within the scoped store; atomically update the pointer only after a complete validated version exists. Define recovery for a created version whose pointer update failed.

## Resolution

New tests, regression analysis, expected results, bug investigation, validation and ordinary reruns resolve the latest active version. A numeric newest draft or retired version is not automatically the latest active requirement. Historical versions require an explicit reproduction or review choice.

Tests and scenarios record exact requirement IDs and versions. When v5 replaces referenced v4, mark dependent records potentially stale and show impact links to manual tests, automation, bugs, documentation and workflows. Staleness indicates review is needed; it does not prove the test is wrong.

## Verification

Create v1 and v2; byte-compare v1 after publication; verify version allocation, active/draft/retired resolution, pointer corruption handling, cross-scope denial, concurrent-edit conflict, historical reproduction, stale-link detection and impact counts. Test interrupted saves and reload behavior without overwriting prior versions.
