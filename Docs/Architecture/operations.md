# Retention, backup, restore and recovery

Status: planned design. Source: [final architecture](final-architecture.txt), sections 137 and 153.
<!-- Source sections: 137,153 -->

Local-first knowledge requires explicit backup and recovery. Operational evidence has different retention needs from authoritative requirements and registered bug history.

## Retention

Configure per-project retention for logs, screenshots, API evidence and database evidence, with keep forever, 30/90 days or custom durations. The source's example durations are illustrative, not a silently applied policy. Requirement history and registered bug metadata must not be automatically removed.

Proposed deletion planning: identify eligible records by scope/type/age, retain explicitly kept or referenced evidence, preview expected impact, and apply recoverable or transactional metadata/file updates as designed. Handle missing files and partial deletion without making the UI claim evidence still exists. Do not let a cleanup job traverse outside its project root.

## Backup contents

Include selected configuration, project memory, requirement versions, Bug Registry, agent/workflow definitions and optionally a consistent SQLite operational snapshot. Track format/schema versions and selected artifact inclusion. Keep secrets separate; normal archives must not export raw Keychain values.

A live SQLite file cannot be copied casually while assuming consistency. Use the chosen database layer's supported backup/snapshot mechanism and test restore. File and database snapshots need an explicit consistency strategy where they reference each other.

## Restore

Validate archive format, checksums, paths, schema compatibility and scope before installation. Proposed flow: inspect/preview, restore into a scoped staging location, validate relationships and migrations, then activate deliberately. Conflicting workspace identities and missing credentials require explicit handling. Do not overwrite the active project blindly.

Restored device credentials/policies are security-sensitive: define whether devices must re-pair and ensure old trust is not revived accidentally. Reconstructed indexes are allowed; missing authoritative history must not be fabricated.

Verify retention exemptions, link preservation, scope containment, disk-full/permission failures, concurrent backup consistency, archive corruption/traversal, interrupted restore, version compatibility, duplicate identities and separate credential recovery. Optional Git configuration backup is covered in [repositories](repositories.md).
