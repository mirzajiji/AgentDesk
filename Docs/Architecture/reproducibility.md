# Environment snapshots, reruns and comparison

Status: planned design. Source: [final architecture](final-architecture.txt), sections 117 and 121–122.
<!-- Source sections: 117,121,122 -->

Important runs record enough non-secret context to explain why results differ over time. A snapshot records what was actually resolved, not merely what the current UI happens to show later.

## Snapshot fields

Capture workspace/project/environment, registered repository, branch, commit and dirty state; agent configuration, skill, workflow and requirement versions; collection/environment versions; database connection identity; plugin/config/MCP versions where discoverable; Codex execution profile; and relevant OS/runtime metadata. Preserve unknown values explicitly. Never embed passwords, tokens or full confidential connection results.

A commit SHA alone cannot reproduce uncommitted changes. Proposed implementation: record a scoped reviewed patch/artifact reference and its hash when policy allows, or label the snapshot incomplete. Do not claim reproducibility when required artifacts, external service state or historical dependencies are unavailable.

## Rerun modes

Normal Run Again resolves current project state and latest active requirements/collections. Reproduce Original Run explicitly selects recorded versions and environment snapshot. Clone Run creates a new execution identity while preserving the selected configuration references; historical records remain intact.

Show differences and missing prerequisites before start. Historical configuration does not revive expired credentials or override current security policy. Reproduction still requires current authorization and must not reset a user's repository or production data automatically.

## Compare runs

Compare inputs, requirements/configuration versions, environment, API/database evidence, execution steps, changed files, failures, duration, Codex profile and artifacts. Preserve provenance and distinguish changed expectations from changed observed behavior. Missing evidence is not evidence of equality.

Verify snapshot immutability, dirty-state handling, current vs original resolution, unsupported/missing historical assets, exact version references, authorization on replay, comparison of absent fields and separation of secrets from reproducibility metadata.
