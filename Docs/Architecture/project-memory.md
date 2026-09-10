# Project memory, retrieval and knowledge relationships

Status: scoped structured memory/notes/inbox storage and scoped FTS search implemented; run-context integration, timeline projections and native management remain planned. Source: [final architecture](final-architecture.txt), sections 11, 12, 17, 103, 107 and 149–151.
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

The [validation record](../Development/p2-05-validation.md) describes limits and tested behavior. Native classification/promotion/attachment screens remain P2-10; selective FTS retrieval and classification-aware context selection remain P2-06. The store does not collect infrastructure data or bypass runtime policy/redaction boundaries.

## Rebuildable search index (P2-06a)

`KnowledgeSearchIndex` uses operational SQLite schema 6 with FTS5 and a generation table. Each instance binds one exact project/environment. It rebuilds from active memory records and latest-active requirements, atomically replacing only its projection. Original JSON is authoritative; the index retains source identity, revision and fingerprint for later revalidation. Indexes are not execution permission or proof that cached behavior is current.

Memory records may include an optional `knowledgePath`, such as `api/paynet/refunds`. Defaults follow the topic. These logical taxonomy paths never access the filesystem. `KnowledgePathFilter` accepts exact paths, a trailing `/**` subtree, or all paths with `**`; exclusion wins. Matching is case-sensitive and respects segment boundaries. Absolute paths, traversal, empty segments and unsupported wildcard forms are rejected. Omitting the optional field preserves older memory encoding/fingerprints.

Titles and JSON bodies pass through the existing scoped redactor before SQLite insertion. A path requiring redaction rejects indexing. Queries default to requirements and confirmed memory; notes/inbox need explicit inclusion. Search uses quoted literal terms joined by AND, with deterministic path/source order. Cursors bind the query/filters, scope, environment and generation; an index rebuild requires a fresh search.

Rebuild limits are 1,000 documents/16 MiB, with 256 KiB per document. Search accepts at most 16 terms/1 KiB and 100 results per page. Failed rebuilds preserve the previous index, while an unbuilt index is distinct from a built empty index. See [index validation](../Development/p2-06a-validation.md). Authoritative revalidation, relationship enrichment and bounded native run-context integration are P2-06b.
