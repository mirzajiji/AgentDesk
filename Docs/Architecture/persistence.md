# Local persistence and recovery

Status: workspace-bound SQLite run records, ordered state events and schema migrations implemented (P1-04); other operational repositories and startup reconciliation remain planned. Source: [final architecture](final-architecture.txt), section 100.
<!-- Source sections: 100 -->

Files are authoritative for readable workspace/project/agent/workflow configuration and structured knowledge. SQLite stores operational state: runs, steps, traces, artifact metadata, approvals, devices, audit events, connection health/metadata, usage and eval results. Actual artifact bytes remain in scoped files; secrets remain in Keychain.

The implementation uses Apple’s system SQLite through a small actor-confined Swift wrapper in `AgentDeskPersistence`. There is no downloaded database dependency. Prepared statements bind every variable value; errors expose SQLite codes without SQL or data. Statements and connections close deterministically, busy waits are bounded to 250 ms, and cancellation rolls back open transactions.

## Proposed storage contract

Bind repositories/stores to explicit workspace/project scopes or require scope on every method. Use schema constraints and indexes to support identity/relationship validation; an ID lookup must not omit authorization. Use parameterized statements and transactional updates for related operational changes.

Maintain an explicit schema version and ordered migrations. Migrations must be tested against real prior-schema fixtures, preserve authoritative relationships and fail visibly rather than silently reset data. Back up before destructive schema transformations where required by the migration plan.

Files and SQLite cannot share an ordinary single-database transaction. Define a recovery protocol for artifact files, immutable versions and indexed metadata: staged writes, atomic rename where supported, durable operation state, and reconciliation of orphaned files or missing index entries. This is a proposal to implement and test, not a guarantee of the current scaffold.

## Concurrency and lifetime

Use actors or the chosen database layer's controlled concurrency boundary. Keep long work outside write transactions. Specify cancellation semantics, busy/lock handling and durable completion before a success event is shown. Use separate scoped temporary directories for tests.

On startup, check schema compatibility and reconcile unfinished operational records. Persist enough state to show interrupted runs accurately; do not claim to resume unrecoverable provider execution. Indexes/caches should be rebuildable without inventing missing authoritative content.

Verify reopen, migrations, rollback, uniqueness/foreign-key constraints, scope predicates, concurrent updates, cancellation, disk-full/permission failures, corrupt pointers and file/database reconciliation. Retention and backup are covered in [operations](operations.md).

## Implemented run journal

`OperationalStore` is bound to one `WorkspaceID`. Every method also requires `ProjectScope`; all queries, updates, keys and event foreign keys include workspace, project and run identities. The application service must validate project membership and operation policy before using the store. A foreign project lookup returns no record. A foreign workspace reference is rejected before SQL execution.

Creating a run atomically writes a queued record and its first event. Recording an authoritative state decision inserts the next sequence and updates the run snapshot in one transaction. An expected sequence rejects concurrent or stale updates. Replay is ordered, bounded and resumes after a supplied sequence. This is a persistence interface, not a run coordinator: valid lifecycle transitions, provider execution, startup interruption recovery and runtime policy arrive in later tasks. No task prompts, secrets or provider output are accepted by the current API.

Schema 1 defines scoped run snapshots. Schema 2 adds ordered events, scoped foreign keys and a project/date index. Migration from schema 1 records each existing snapshot as sequence 1; it does not reconstruct earlier transitions or claim historical timing beyond the stored snapshot date. An application identifier and schema version distinguish this database from unrelated files. Migrations are transactional, refuse future versions, and never reset failed/corrupt databases.

The location must be an explicit caller-authorized application storage container with the fixed filename `operations.sqlite`. New files are created with owner-only permissions; existing database/sidecar symlinks, hardlinks and non-regular files are rejected, and SQLite opens with no-follow protection. The containing directory is trusted application storage, not a user-supplied workspace-relative path. Like the configuration catalog, this does not claim isolation against hostile processes with the same OS filesystem authority. The system rollback journal is used; WAL and connection pooling are not enabled. The Xcode app and its native unit target link the package; the UI will consume run history with the coordinator.
