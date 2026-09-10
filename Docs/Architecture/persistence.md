# Local persistence and recovery

Status: workspace-bound SQLite run records, ordered state/progress events, validated work-plan snapshots and schema migrations are implemented (P1-04/P1-07b); P1-10 adds project/environment approval and audit records; P1-12b adds redacted trace/artifact storage and file reconciliation. Provider coordination and interrupted-run startup handling remain subsequent work. Source: [final architecture](final-architecture.txt), section 100.
<!-- Source sections: 100 -->

Files are authoritative for readable workspace/project/agent/workflow configuration and structured knowledge. SQLite stores operational state: runs, steps, traces, artifact metadata, approvals, devices, audit events, connection health/metadata, usage and eval results. Actual artifact bytes remain in scoped files; secrets remain in Keychain.

The implementation uses Apple’s system SQLite through a small actor-confined Swift wrapper in `AgentDeskPersistence`. There is no downloaded database dependency. Prepared statements bind every variable value; errors expose SQLite codes without SQL or data. Statements and connections close deterministically, busy waits are bounded to 250 ms, and cancellation rolls back open transactions.

## Proposed storage contract

Bind repositories/stores to explicit workspace/project scopes or require scope on every method. Use schema constraints and indexes to support identity/relationship validation; an ID lookup must not omit authorization. Use parameterized statements and transactional updates for related operational changes.

Maintain an explicit schema version and ordered migrations. Migrations must be tested against real prior-schema fixtures, preserve authoritative relationships and fail visibly rather than silently reset data. Back up before destructive schema transformations where required by the migration plan.

Files and SQLite cannot share an ordinary single-database transaction. Artifact storage now uses the publication/recovery protocol below. Other repositories must likewise define their own staged writes, durable state and reconciliation before claiming cross-file/database consistency.

## Concurrency and lifetime

Use actors or the chosen database layer's controlled concurrency boundary. Keep long work outside write transactions. Specify cancellation semantics, busy/lock handling and durable completion before a success event is shown. Use separate scoped temporary directories for tests.

On startup, check schema compatibility and reconcile unfinished operational records. Persist enough state to show interrupted runs accurately; do not claim to resume unrecoverable provider execution. Indexes/caches should be rebuildable without inventing missing authoritative content.

Verify reopen, migrations, rollback, uniqueness/foreign-key constraints, scope predicates, concurrent updates, cancellation, disk-full/permission failures, corrupt pointers and file/database reconciliation. Retention and backup are covered in [operations](operations.md).

## Implemented run journal

`OperationalStore` is bound to one `WorkspaceID`. Every method also requires `ProjectScope`; all queries, updates, keys and event foreign keys include workspace, project and run identities. The application service must validate project membership and operation policy before using the store. A foreign project lookup returns no record. A foreign workspace reference is rejected before SQL execution.

Creating a run atomically writes a queued record and its first event. Recording an authoritative state decision inserts the next sequence and updates the run snapshot in one transaction. An expected sequence rejects concurrent or stale updates. Replay is ordered, bounded and resumes after a supplied sequence. The Runtime lifecycle service enforces legal state transitions; the internal provider and policy gate now exist separately, while persisted execution coordination and startup interruption recovery remain subsequent tasks. The lifecycle API accepts no task prompts or provider output; the separate evidence API below requires sanitized content.

Schema 1 defines scoped run snapshots. Schema 2 adds ordered events, scoped foreign keys and a project/date index. Migration from schema 1 records each existing snapshot as sequence 1; it does not reconstruct earlier transitions or claim historical timing beyond the stored snapshot date. An application identifier and schema version distinguish this database from unrelated files. Migrations are transactional, refuse future versions, and never reset failed/corrupt databases.

Schema 3 adds the event kind and optional validated progress JSON to the existing journal, plus scoped `run_progress` snapshots. Existing schema-2 events become `runState` events without invented work plans. Configuring/updating a plan or finalizing it with a terminal run state writes snapshot and journal atomically. Every payload is decoded and validated against its query's workspace/project/run identity. A copied foreign payload or invalid state graph fails closed. JSON payloads are bounded to 128 KiB; ordinary SQL text values retain the existing 64 KiB limit. Terminal snapshots remain within the bound even at the maximum supported plan size. Canonical Unix-time dates are used for both returned/live and reopened records.

The location must be an explicit caller-authorized application storage container with the fixed filename `operations.sqlite`. New files are created with owner-only permissions; existing database/sidecar symlinks, hardlinks and non-regular files are rejected, and SQLite opens with no-follow protection. The containing directory is trusted application storage, not a user-supplied workspace-relative path. Like the configuration catalog, this does not claim isolation against hostile processes with the same OS filesystem authority. The system rollback journal is used; WAL and connection pooling are not enabled. The Xcode app and its native unit target link the package; the UI will consume run history with the coordinator.


Schema 4 adds `approvals` and `approval_events` without rewriting runs or progress. Both keys and audit foreign keys include workspace, project, environment and approval ID; action IDs are unique within that context. `ApprovalStore` validates immutable action JSON against the queried scope and identity, performs optimistic-sequence transitions in immediate transactions and commits each state with its audit event. Prepare, approve/reject, expiry, modify-and-approve and one-time consumption are durable. A failure inserting an audit event rolls back related state and replacement records together. Reads/replays are bounded and contain no raw prompts, commands, resources or secret values. The lower-level store is not an authentication boundary; callers must use the Runtime gate. See [approvals](permissions.md) and [validation](../Development/p1-10-validation.md).

Migration is forward-only and tested from version 3 while preserving run rows. An older binary that only understands schema 3 will refuse the upgraded database; it must not reset or downgrade it. Approval consumption before dispatch gives at most one authorized attempt, not exactly-once delivery to an external service. Run reconciliation must distinguish an attempted/uncertain effect from observed success.

## Implemented trace and artifact boundary

Schema 5 adds `evidence_runs` and `evidence_items`, preserving schema-4 runs, approvals and events. A queued run registers an immutable binding: workspace/project/run/environment, agent and exact revision, effective-configuration fingerprint and redacted environment/configuration snapshot. Each run can bind only one environment; existing runs are not assigned invented environments or snapshots by migration. Identical registration is idempotent even after execution starts; changed bindings and first-time registration after queued state are refused.

`EvidenceStore` is bound to that context and agent. Every read, write and recovery query verifies the binding; keys and foreign keys include all context IDs. Callers must first authorize access through the runtime policy gate. Store construction and possession of an ID do not grant access. The store accepts only `RedactedText` from the [central redactor](security.md), never raw provider chunks or arbitrary filenames. Snapshots and traces allow 64 KiB of sanitized UTF-8; larger bounded output belongs in an artifact. The store does not silently truncate evidence.

Each evidence record has a caller-retained UUID retry key, an ordered sequence, timestamp, source, observed/interpretation basis, format hint, kind, classification, redaction count/version, byte count and SHA-256 fingerprint of the **sanitized** bytes. Provider responses must be marked interpretation; verified command output can be observed evidence. Format is a rendering hint, not executable content or a new schema-validation claim. Stored content cannot be passed back into a write API as proof of fresh redaction. Whole SECRET classifications, mismatched contexts, malformed stored metadata, changed trace bytes, unsupported redaction versions and inconsistent hashes fail closed.

Traces live in SQLite. Artifact metadata lives there too, while artifact bytes are private text files under the authorized operational database container:

```text
Evidence/<workspace>/<project>/<environment>/<run>/<artifact-uuid>.txt
```

All names derive from validated IDs. Descriptor-relative operations reject directory/file symlinks, hardlinks and non-regular files; FIFO reads cannot block. New directories use 0700 and files 0600. The store returns verified content, not unchecked filesystem URLs. It rechecks file type, size, UTF-8 and fingerprint on every artifact read. The containing application storage directory is trusted; this does not claim protection against a hostile process with the same operating-system authority or cryptographic authenticity against an attacker able to rewrite both metadata and files.

## Artifact publication and reconciliation

Publication serializes through a bounded SQLite immediate transaction. It checks binding, lifecycle state and retry identity before writing. Files are written to exclusive temporary names, synchronized, atomically renamed without replacement, and the directory is synchronized before metadata commits. A successful return therefore follows both file publication and the SQLite commit. New records are refused after terminal run state; an exact retry may still repair the originally published artifact.

Files and database remain separate durability domains. A failure/interruption after rename but before metadata commit leaves a complete **unpublished orphan**. No API returns its contents as a stored artifact. `recover` reports missing/corrupt/unsafe published files, orphan IDs, staged-file counts and unexpected-file counts without exposing arbitrary filenames or raw contents. It preserves these files rather than deleting potentially useful evidence. An exact retry with the original UUID, content, timestamp and provenance adopts an identical orphan or repairs a missing file. Different bytes/provenance never overwrite the original; corrupt published files remain unavailable for explicit investigation.

Recovery reads one run under the same database serialization boundary as publication. Cancellation releases transactions; file cleanup removes only a temporary file created by that operation. A crash can leave staged files, which remain reported and unpublished. Metadata insertion failures and permission failures do not return successful records. Recovery supplies evidence availability, not a claim that an interrupted Codex operation succeeded or can resume.

Limits: 4,096 total records per run, 256 records per replay page, 1 MiB per artifact, 64 KiB per trace/snapshot and 4,096 directory entries per recovery inventory. Snapshot envelopes are bounded to 128 KiB and metadata to 4 KiB. Recovery is explicit, may perform bounded disk I/O across the run, and can encounter the existing 250 ms SQLite busy limit when another connection is active. Retention, binary artifacts, automatic cleanup, export/mobile projections and run-level startup coordination remain later capabilities. See [evidence validation](../Development/p1-12b-validation.md).


P1-11a adds project-scoped keyset pagination for unfinished runs (up to 256 per page) and verified lookup of a run's immutable evidence binding. Recovery verifies the stored environment column against decoded scope/run/environment identity; malformed or inconsistent metadata is an explicit database error. No schema migration is needed: the database remains version 5. Only the trusted project execution owner uses these reads to recover interrupted runs; wire clients do not gain cross-environment read access. See the [coordinator contract](execution.md).
