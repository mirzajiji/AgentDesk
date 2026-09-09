# Local persistence and recovery

Status: planned design. Source: [final architecture](final-architecture.txt), section 100.
<!-- Source sections: 100 -->

Files are authoritative for readable workspace/project/agent/workflow configuration and structured knowledge. SQLite stores operational state: runs, steps, traces, artifact metadata, approvals, devices, audit events, connection health/metadata, usage and eval results. Actual artifact bytes remain in scoped files; secrets remain in Keychain.

The source suggests GRDB or a similarly controlled SQLite layer. Driver selection and dependency version are implementation decisions to verify; no dependency has been installed by this documentation task.

## Proposed storage contract

Bind repositories/stores to explicit workspace/project scopes or require scope on every method. Use schema constraints and indexes to support identity/relationship validation; an ID lookup must not omit authorization. Use parameterized statements and transactional updates for related operational changes.

Maintain an explicit schema version and ordered migrations. Migrations must be tested against real prior-schema fixtures, preserve authoritative relationships and fail visibly rather than silently reset data. Back up before destructive schema transformations where required by the migration plan.

Files and SQLite cannot share an ordinary single-database transaction. Define a recovery protocol for artifact files, immutable versions and indexed metadata: staged writes, atomic rename where supported, durable operation state, and reconciliation of orphaned files or missing index entries. This is a proposal to implement and test, not a guarantee of the current scaffold.

## Concurrency and lifetime

Use actors or the chosen database layer's controlled concurrency boundary. Keep long work outside write transactions. Specify cancellation semantics, busy/lock handling and durable completion before a success event is shown. Use separate scoped temporary directories for tests.

On startup, check schema compatibility and reconcile unfinished operational records. Persist enough state to show interrupted runs accurately; do not claim to resume unrecoverable provider execution. Indexes/caches should be rebuildable without inventing missing authoritative content.

Verify reopen, migrations, rollback, uniqueness/foreign-key constraints, scope predicates, concurrent updates, cancellation, disk-full/permission failures, corrupt pointers and file/database reconciliation. Retention and backup are covered in [operations](operations.md).
