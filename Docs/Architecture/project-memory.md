# Project memory, retrieval and knowledge relationships

Status: scoped structured memory/notes/inbox storage, FTS search and selective run-context integration implemented; native memory management implemented and validated in P2-10a. Timeline projections remain planned. Run-context acceptance is tracked in P2-06b. Source: [final architecture](final-architecture.txt), sections 11, 12, 17, 103, 107 and 149–151.
<!-- Source sections: 11,12,17,103,107,149,150,151 -->

Project Memory holds reusable confirmed knowledge: project descriptions, accepted behavior, rules, API/state/environment semantics, test expectations, architecture, QA decisions, terminology and linked defects. Store separate structured JSON records rather than one growing monolithic document.

## Information classes

| Class | Meaning | Promotion behavior |
| --- | --- | --- |
| Run context | Information relevant to a single execution | Does not automatically become permanent |
| Evidence | Observed technical facts and source metadata | Retain provenance and classification |
| Project memory | Reusable confirmed knowledge | Review proposed changes |
| Requirement | Versioned authoritative expected behavior | New immutable version for changes |
| Bug registry | Known defects and external associations | Preserve duplicate/evidence relationships |
| Notes | Manual or uncertain findings | Explicit promotion to other record types |
| Inbox | Imported information with unresolved destination | User classifies, attaches, promotes or dismisses |

An agent may propose a requirement or memory update. It must not silently convert ambiguous statements, analysis or imported screenshots into authoritative behavior.

## Retrieval

Search is scoped to the active workspace/project by default. Start with metadata, structured relationships and SQLite FTS5 indexing; retain an abstraction for future local semantic search. Agents can declare include/exclude knowledge paths. Scope and classification checks occur before results enter context.

Do not inject the whole project into every request. Build a bounded context selection tied to the task, with record IDs, requirement versions and source references shown in the context inspector. Missing or contradictory knowledge should remain visible rather than filled with invented rules.

An explicit global dashboard/search mode may aggregate allowed metadata. It must not silently combine confidential company content into model context or weaken underlying access checks.

## Relationship graph and timeline

Track requirement versions linked to tests, automation, bugs, documentation and workflows. Support questions about current behavior, changes, stale tests, coverage, blocked scenarios and known ticket associations. Project timeline events include requirement changes, runs, collection imports, duplicate findings, evidence attachments and approved actions.

Proposed implementation: indexes and timeline projections are rebuildable from authoritative records and operational events. Deleted or unavailable sources should produce clear dangling-reference states rather than silently rewriting history.

## Verification

Test selective retrieval and exclusions, two-project/workspace isolation, latest vs historical requirement resolution, FTS index rebuilds, stale references, note/inbox promotion, classification filtering and source provenance. A generated interpretation must remain distinguishable from observed evidence after persistence and reload.

## Scoped memory storage (P2-05)

`WorkspaceCatalog.memoryStore(in:)` opens a trusted local administrative store. Memory kinds are confirmed knowledge, notes and unclassified inbox items. Topics distinguish descriptions, rules, API/state/environment behavior, test expectations, architecture, QA decisions, discoveries, terminology and documentation. Requirements and bugs retain their dedicated domain stores.

`capture` creates only active nonauthoritative notes/inbox records. It cannot update an existing ID or confirm knowledge. `prepare` creates an exact in-memory review proposal; `publishReviewed` checks token/store/scope, expiry and unchanged base before committing. Cancellation writes no authoritative files. The same review path governs confirmation, classification, edits, archive and ignored-inbox disposition. Confirmation requires a classified topic and preserves source origin; review does not turn an interpretation into observed evidence.

Each record has `Memory/Knowledge/<UUID>/entry.vN.json` versions and a `current.json` pointer. Fields include scoped identity, revision/ancestry fingerprints, title, body, structured JSON, kind/topic/disposition, tags, environments, provenance and reason. Sources include origin (observed, human statement or interpretation), scoped execution identity when applicable, capture time and inert references. Source timestamps retain fractional precision using the standard Codable Date representation (numeric seconds since 2001-01-01 UTC). References are not automatically fetched or treated as paths.

Publication exclusively creates a version before advancing the pointer. Partial orphan versions are not adopted or overwritten. Historical chains validate scope, identity, fingerprints and date order; malformed pointers, tampering, symlinks and multiply linked files fail closed. Reads/listings are scope checked and bounded. Listing defaults to active records and can filter kinds/environments; ignored/archived records require explicit inclusion. Administrative listing does not itself authorize model context inclusion.

The [validation record](../Development/p2-05-validation.md) describes limits and tested behavior. Native classification/promotion/attachment screens remain P2-10; selective FTS retrieval and classification-aware context selection are covered by P2-06a/b. The store does not collect infrastructure data or bypass runtime policy/redaction boundaries.

## Rebuildable search index (P2-06a)

`KnowledgeSearchIndex` uses operational SQLite schema 6 with FTS5 and a generation table. Each instance binds one exact project/environment. It rebuilds from active memory records and latest-active requirements, atomically replacing only its projection. Original JSON is authoritative; the index retains source identity, revision and fingerprint for later revalidation. Indexes are not execution permission or proof that cached behavior is current.

Memory records may include an optional `knowledgePath`, such as `api/paynet/refunds`. Defaults follow the topic. These logical taxonomy paths never access the filesystem. `KnowledgePathFilter` accepts exact paths, a trailing `/**` subtree, or all paths with `**`; exclusion wins. Matching is case-sensitive and respects segment boundaries. Absolute paths, traversal, empty segments and unsupported wildcard forms are rejected. Omitting the optional field preserves older memory encoding/fingerprints.

Titles and JSON bodies pass through the existing scoped redactor before SQLite insertion. A path requiring redaction rejects indexing. Queries default to requirements and confirmed memory; notes/inbox need explicit inclusion. Search uses quoted literal terms joined by AND, with deterministic path/source order. Cursors bind the query/filters, scope, environment and generation; an index rebuild requires a fresh search.

Rebuild limits are 1,000 documents/16 MiB, with 256 KiB per document. Search accepts at most 16 terms/1 KiB and 100 results per page. Failed rebuilds preserve the previous index, while an unbuilt index is distinct from a built empty index. See [index validation](../Development/p2-06a-validation.md). Authoritative revalidation, relationship enrichment and bounded native run-context integration are described below.

## Selective run context (P2-06b)

An agent's **Knowledge** tab enables explicit include/exclude paths, query terms, classifications and context budgets. Existing agents have no selection and retrieve nothing. New selections default to active requirements and confirmed memory; notes and inbox are opt-in and retain their origin/classification. Empty includes match nothing. Preferences are saved with the agent revision and included in the effective execution fingerprint. Paths are taxonomy labels, not file grants.

`KnowledgeCandidateSearching` is the real discovery boundary for FTS and future search implementations. `KnowledgeContextService` discards cached bodies and reopens authoritative records in the exact project/environment. A changed cache revision/hash is reported as stale, never used as current evidence. Archived, retired, missing and environment-inapplicable sources are unavailable. Fresh records must still pass the path and classification selection even if a search backend returns an invalid selection.

Explicit structured subjects use `kind/id` (automatedTest, manualTest, bug, documentation or workflow). Their reviewed links select the latest active requirement, not the historical version attached when the link was created. These references take priority over FTS candidates, still obey path/classification/environment selection, and remain bound to the reviewed trace revision. A nonmatching search term does not disable an explicitly chosen relationship.

Preparation first authorizes the run and evidence read, then rebuilds the scoped index and assembles context. The complete redacted packet is limited to 1–32 records and 1–32 KiB. FTS discovery considers at most 32 candidates; relationship discovery considers at most 64 references from 16 subjects. Omission is explicit. Records are not sliced into misleading fragments; if necessary whole records are omitted. Oversized metadata diagnostics fail preparation instead of silently losing provenance. The native console’s **Inspect Selected Knowledge** sheet presents source IDs, revisions, paths, classifications, bodies, provenance and sanitized fingerprints as readable sections before approval. The original sanitized packet remains bound to dispatch; display formatting does not change it.

Raw source-history fingerprints remain in the in-memory revalidation closure; persisted input contains fingerprints of sanitized bytes. Original source provenance remains distinct from interpretation. The exact packet is appended to the task as untrusted data and included in the existing input/dispatch fingerprint. Enabling selection without a reader fails preparation. Before approval consumption and again immediately before provider dispatch, selected source and relationship fingerprints are checked against current files. Changed sources require another preparation. A concurrent external edit immediately after this last check cannot be made atomic with starting an external process; the persisted packet still records the exact reviewed input used by that run.

See the [P2-06b validation record](../Development/p2-06b-validation.md) for acceptance status. This adds no automatic knowledge promotion, semantic search, global company aggregation or external infrastructure access.

## Native memory management (P2-10a)

Open **Memory** beside a project, or search the command palette for its memory, notes or inbox action. Routing resolves the current project scope; names are labels, not identity. The browser shows current records with kind, environment and archived/ignored filters. Literal case/diacritic-insensitive search checks current title, body, structured JSON, tags and logical path directly in the authoritative store, bounded to 1,024 characters and 50 matching records per page. This administrative search is separate from the run-context FTS index. Changing a filter resets pagination and selection.

**New Memory** starts a note with a local human-statement source. Choose a kind/topic and provide content and a version reason. The **Scope & Sources** tab retains environment selections and displays provenance; **Structured Fields** supports validated JSON edits to structured content and source metadata. Unknown stored environments are preserved if Setup is unavailable. Cross-project sources and invalid classifications fail validation.

**Review Changes** prepares the exact sanitized candidate and presents changed fields with before/after values. **Publish Version** is the explicit local administrative review action. Cancelling a review writes nothing. Confirmation requires a topic and keeps source origin intact. Editing, archiving and ignoring an inbox entry all create immutable versions. Concurrent changes or expired proposals require another review. The version picker inspects earlier content; **Edit Latest Version** always starts from the current version. An archived/ignored result disappears from the default list and can be reopened with **Include archived/ignored**.

Native display and publication use centralized content redaction before presenting existing content or preparing a candidate. The local preview uses an ephemeral redaction context that is never recorded as execution provenance. It does not read or enumerate Keychain secrets. The browser shows source identity and content rather than exposing raw integrity hashes as output evidence. Original version files remain authoritative; masking their display does not rewrite history.

The views adapt to logical window sizes with scrollable forms and reachable review controls. This is a Mac administrative flow; it does not grant mobile configuration authority or perform automatic knowledge promotion. See [P2-10a validation](../Development/p2-10a-validation.md) for current acceptance and platform coverage.
